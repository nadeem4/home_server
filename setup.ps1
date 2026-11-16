<#
.SYNOPSIS
  One-stop setup: asks a few questions, creates server.local.env (hashing your password with
  OpenSSL), then offers to build the USB stick.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\setup.ps1
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\render.ps1"
$EnvFile = "$PSScriptRoot\server.local.env"

function Ask([string]$Question, [string]$Default) {
    $answer = Read-Host "$Question [$Default]"
    if ($answer) { $answer.Trim() } else { $Default }
}

function Read-Password {
    while ($true) {
        $a = Read-Host 'Server login password (for the console and Cockpit)' -AsSecureString
        $b = Read-Host 'Type it again' -AsSecureString
        $pa = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($a))
        $pb = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($b))
        if (-not $pa) { Write-Host 'Password must not be empty.' -ForegroundColor Yellow; continue }
        if ($pa -ne $pb) { Write-Host 'The passwords did not match. Try again.' -ForegroundColor Yellow; continue }
        return $pa
    }
}

# Asks twice for the Wi-Fi password (hidden), like Read-Password. Must be 8-63 printable ASCII characters.
function Read-WifiPassword {
    while ($true) {
        $a = Read-Host 'Wi-Fi password' -AsSecureString
        $b = Read-Host 'Type it again' -AsSecureString
        $pa = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($a))
        $pb = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($b))
        if (-not (Test-WifiPassword $pa)) { Write-Host 'Wi-Fi password must be 8-63 printable ASCII characters (letters, digits, symbols; no accents).' -ForegroundColor Yellow; continue }
        if ($pa -ne $pb) { Write-Host 'The passwords did not match. Try again.' -ForegroundColor Yellow; continue }
        return $pa
    }
}

Write-Host "`n== Home server setup ==`n"

# 1. Create server.local.env (or keep the existing one).
$create = $true
if (Test-Path $EnvFile) {
    $create = (Ask 'server.local.env already exists. Create a new one? (y/n)' 'n') -eq 'y'
}
if ($create) {
    $values = @{
        SERVER_USER       = Ask 'Login user name' ($env:USERNAME.ToLower() -replace '[^a-z0-9-]', '')
        TIMEZONE          = Ask 'Time zone (detected from this PC)' (Get-LocalIanaTimeZone)
        BATTERY_START     = Ask 'Start charging below (%)' '60'
        BATTERY_STOP      = Ask 'Stop charging at (%)' '80'
    }
    Write-Host 'Tailscale auth key (optional): create a reusable key at https://login.tailscale.com/admin/settings/keys'
    Write-Host 'With it, the server joins your Tailscale network by itself. Press Enter to skip.'
    $values.TAILSCALE_AUTHKEY = (Read-Host 'Tailscale auth key').Trim()
    $values.PASSWORD_HASH = ConvertTo-PasswordHash (Read-Password)
    # Wi-Fi (optional): the server keeps only the network name and a derived key, not the password.
    $detected = Get-LocalWifiSsid
    $prompt = if ($detected) { "Wi-Fi network (Enter for '$detected', - to skip)" } else { 'Wi-Fi network (Enter to skip)' }
    while ($true) {
        $ssid = (Read-Host $prompt).Trim()
        if (-not $ssid) { $ssid = $detected }
        if (-not $ssid -or $ssid -eq '-' -or (Test-WifiSsid $ssid)) { break }
        Write-Host 'A Wi-Fi name is at most 32 bytes. Try again.' -ForegroundColor Yellow
    }
    if ($ssid -and $ssid -ne '-') {
        $values.WIFI_SSID = $ssid
        $values.WIFI_PSK = ConvertTo-WifiPsk $ssid (Read-WifiPassword)
    }

    Test-ServerConfig $values
    Set-Content -LiteralPath $EnvFile -Value (Format-EnvFile $values) -Encoding UTF8
    Write-Host "Saved $EnvFile (your password is stored only as a hash)." -ForegroundColor Green
} else {
    Test-ServerConfig (Read-EnvFile $EnvFile)
    Write-Host 'Keeping the existing server.local.env.'
}

# 2. Offer to build the USB stick.
$usbDisks = @(Get-Disk | Where-Object BusType -eq 'USB')
if (-not $usbDisks.Count) {
    Write-Host "`nNo USB stick found. Plug one in and run this again, or run build-usb.ps1 later."
    exit 0
}
Write-Host "`nUSB disks:"
$usbDisks | ForEach-Object { Write-Host ("  {0}: {1}, {2} GB" -f $_.Number, $_.FriendlyName, [math]::Round($_.Size / 1GB, 1)) }
$n = Read-Host "`nDisk number to turn into the installer (it will be ERASED), or Enter to stop here"
if (-not $n) { Write-Host 'Stopped. Build later with build-usb.ps1.'; exit 0 }

# build-usb.ps1 needs administrator rights, so start it in an elevated window.
$buildArgs = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSScriptRoot\build-usb.ps1`"", '-DiskNumber', $n, '-EnvFile', "`"$EnvFile`"")
Start-Process powershell -Verb RunAs -ArgumentList $buildArgs
Write-Host 'Opened an Administrator window to build the USB stick. Follow it there.'
