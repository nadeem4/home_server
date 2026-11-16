# Helpers for build-usb.ps1: read the local config, check it, fill the templates.

$RequiredKeys = @(
    'SERVER_USER', 'PASSWORD_HASH', 'TIMEZONE',
    'TAILSCALE_AUTHKEY', 'BATTERY_START', 'BATTERY_STOP'
)

# Reads KEY=VALUE lines. Blank lines and lines starting with # are skipped.
# Values are taken literally (no quotes, no $ expansion).
function Read-EnvFile([string]$Path) {
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { throw "Bad line in ${Path}: '$line' (expected KEY=VALUE)" }
        $values[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    $values
}

# Replaces {{KEY}} with its value. Throws if a key is missing, or if a value
# holds a quote or newline (it would break the YAML or shell file it goes into).
function Expand-Template([string]$Template, [hashtable]$Values) {
    $keys = [regex]::Matches($Template, '\{\{(\w+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    $missing = @($keys | Where-Object { -not $Values.ContainsKey($_) })
    if ($missing.Count) { throw "Missing values: $($missing -join ', ')" }
    foreach ($k in $keys) {
        if ($Values[$k] -match "['`"`r`n]") { throw "Value of $k must not contain quotes or newlines" }
    }
    [regex]::Replace($Template, '\{\{(\w+)\}\}', { param($m) $Values[$m.Groups[1].Value] })
}

# Checks the config and throws one error listing every problem found.
function Test-ServerConfig([hashtable]$Values) {
    $problems = @()
    foreach ($k in $RequiredKeys) {
        if (-not $Values.ContainsKey($k)) { $problems += "$k is missing" }
    }
    if ($problems.Count) { throw ($problems -join '; ') }

    if ($Values.SERVER_USER -notmatch '^[a-z][a-z0-9-]{0,31}$') {
        $problems += 'SERVER_USER must start with a lowercase letter (letters, digits, dashes)'
    }
    if ($Values.PASSWORD_HASH -notmatch '^\$6\$') {
        $problems += 'PASSWORD_HASH must be a SHA-512 hash starting with $6$ (see README)'
    }
    $start = 0; $stop = 0
    if (-not ([int]::TryParse($Values.BATTERY_START, [ref]$start) -and [int]::TryParse($Values.BATTERY_STOP, [ref]$stop)) -or
        $start -lt 0 -or $stop -gt 100 -or $start -ge $stop) {
        $problems += 'BATTERY_START and BATTERY_STOP must be 0-100 with START below STOP (e.g. 60 and 80)'
    }
    # Wi-Fi is optional (older env files have none), but an SSID needs its key.
    if ($Values.WIFI_SSID -and $Values.WIFI_PSK -notmatch '^[0-9a-f]{64}$') {
        $problems += 'WIFI_PSK must be 64 lowercase hex characters when WIFI_SSID is set (setup.ps1 makes it)'
    }
    if ($problems.Count) { throw ($problems -join '; ') }
}

# Turns a Wi-Fi password into the 64-hex WPA2 key (PBKDF2-HMAC-SHA1, SSID as salt, 4096 rounds).
# The server gets only this key, never the password.
function ConvertTo-WifiPsk([string]$Ssid, [string]$Password) {
    if ($Password.Length -lt 8 -or $Password.Length -gt 63) { throw 'Wi-Fi password must be 8-63 characters.' }
    # Done by hand: .NET's Rfc2898DeriveBytes refuses salts under 8 bytes, but SSIDs can be shorter.
    $hmac = New-Object Security.Cryptography.HMACSHA1 (, [Text.Encoding]::UTF8.GetBytes($Password))
    $salt = [Text.Encoding]::UTF8.GetBytes($Ssid)
    $key = foreach ($block in 1, 2) {
        $u = $hmac.ComputeHash([byte[]]($salt + [byte[]](0, 0, 0, $block)))
        $t = [byte[]]$u.Clone()
        for ($i = 1; $i -lt 4096; $i++) {
            $u = $hmac.ComputeHash($u)
            for ($j = 0; $j -lt 20; $j++) { $t[$j] = $t[$j] -bxor $u[$j] }
        }
        $t
    }
    (($key | Select-Object -First 32 | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Finds the connected network in `netsh wlan show interfaces` text ('' if none).
# Matches the "SSID" line only, not "BSSID".
function Get-WifiSsidFromNetsh([string[]]$Lines) {
    foreach ($line in $Lines) {
        if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$') { return $Matches[1] }
    }
    ''
}

# The Wi-Fi network this PC is connected to ('' if none or no Wi-Fi adapter).
function Get-LocalWifiSsid {
    Get-WifiSsidFromNetsh @(netsh wlan show interfaces 2>$null)
}

# Hashes a password with OpenSSL (SHA-512 crypt, random salt), as Ubuntu expects.
# The password goes in on stdin, so it never shows up in a process list.
function ConvertTo-PasswordHash([string]$Password, [string]$OpenSsl) {
    if (-not $Password) { throw 'Password must not be empty.' }
    if (-not $OpenSsl) { $OpenSsl = (Get-Command openssl -ErrorAction SilentlyContinue).Source }
    if (-not $OpenSsl) { $OpenSsl = 'C:\Program Files\Git\usr\bin\openssl.exe' }
    if (-not (Test-Path $OpenSsl)) { throw 'OpenSSL not found. Install Git for Windows (https://git-scm.com).' }
    # Capture OpenSSL's error output too, so a failure says why. 'Continue' keeps that
    # output from being turned into a terminating error when the caller uses 'Stop'.
    $ErrorActionPreference = 'Continue'
    $out = @($Password | & $OpenSsl passwd -6 -stdin 2>&1 | ForEach-Object { "$_" })
    $hash = $out | Where-Object { $_ -match '^\$6\$' } | Select-Object -First 1
    if ($LASTEXITCODE -or -not $hash) {
        throw "OpenSSL did not return a password hash. OpenSSL used: $OpenSsl (exit code $LASTEXITCODE). Its output: $($out -join ' ')"
    }
    $hash.Trim()
}

# Time zones: Windows and Linux name them differently ("Central Standard Time" vs
# "America/Chicago"). Windows 10 1903+ ships ICU (icu.dll), which converts between them.
if (-not ('HomeServer.Icu' -as [type])) {
    Add-Type -Namespace HomeServer -Name Icu -MemberDefinition @'
[DllImport("icu.dll", CharSet = CharSet.Unicode)]
public static extern int ucal_getTimeZoneIDForWindowsID(string winid, int len, IntPtr region,
    System.Text.StringBuilder id, int idCapacity, ref int status);
[DllImport("icu.dll", CharSet = CharSet.Unicode)]
public static extern int ucal_getWindowsTimeZoneID(string id, int len,
    System.Text.StringBuilder winid, int winidCapacity, ref int status);
[DllImport("icu.dll", CharSet = CharSet.Unicode)]
public static extern int ucal_getIanaTimeZoneID(string id, int len,
    System.Text.StringBuilder result, int resultCapacity, ref int status);
'@
}

# Converts a Windows time zone name to its IANA name, or Etc/UTC if there is none.
function ConvertTo-IanaTimeZone([string]$WindowsId) {
    $sb = New-Object Text.StringBuilder 128; $status = 0
    $n = [HomeServer.Icu]::ucal_getTimeZoneIDForWindowsID($WindowsId, $WindowsId.Length, [IntPtr]::Zero, $sb, $sb.Capacity, [ref]$status)
    if ($status -gt 0 -or $n -le 0) { return 'Etc/UTC' }
    $id = $sb.ToString(0, $n)
    # ICU may return an old alias (e.g. Asia/Calcutta) that newer Ubuntu releases no longer ship.
    # ICU 74+ can give the current IANA name; older ICU lacks the function, so keep the alias then.
    try {
        $cur = New-Object Text.StringBuilder 128; $status = 0
        $m = [HomeServer.Icu]::ucal_getIanaTimeZoneID($id, $id.Length, $cur, $cur.Capacity, [ref]$status)
        if ($status -le 0 -and $m -gt 0) { $id = $cur.ToString(0, $m) }
    } catch [EntryPointNotFoundException] { }
    $id
}

# Converts an IANA time zone name to its Windows name (used to check the conversion).
function ConvertTo-WindowsTimeZone([string]$IanaId) {
    $sb = New-Object Text.StringBuilder 128; $status = 0
    $n = [HomeServer.Icu]::ucal_getWindowsTimeZoneID($IanaId, $IanaId.Length, $sb, $sb.Capacity, [ref]$status)
    if ($status -gt 0 -or $n -le 0) { return $null }
    $sb.ToString(0, $n)
}

# The IANA time zone of the PC this runs on.
function Get-LocalIanaTimeZone {
    ConvertTo-IanaTimeZone (Get-TimeZone).Id
}

# Wipes a disk and leaves it empty with an MBR partition table.
# Windows may keep the old partition style after a wipe instead of making the disk blank (RAW).
function Reset-UsbDisk([int]$DiskNumber) {
    if ((Get-Disk -Number $DiskNumber).PartitionStyle -ne 'RAW') {
        Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    }
    $style = (Get-Disk -Number $DiskNumber).PartitionStyle
    if ($style -eq 'RAW') { Initialize-Disk -Number $DiskNumber -PartitionStyle MBR }
    elseif ($style -ne 'MBR') { Set-Disk -Number $DiskNumber -PartitionStyle MBR }
}

# Turns a config into server.local.env text, in the order of $RequiredKeys.
function Format-EnvFile([hashtable]$Values) {
    $lines = @('# Created by setup.ps1. Never commit this file.')
    foreach ($k in $RequiredKeys) { $lines += "$k=$($Values[$k])" }
    if ($Values.WIFI_SSID) { $lines += "WIFI_SSID=$($Values.WIFI_SSID)"; $lines += "WIFI_PSK=$($Values.WIFI_PSK)" }
    $lines
}

# Writes text with LF line endings and no BOM, as Linux expects.
function Write-LfFile([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
}
