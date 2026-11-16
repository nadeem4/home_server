# Pester 3.4 tests (ships with Windows). Run: Invoke-Pester -Path .\tests
$root = Split-Path -Parent $PSScriptRoot
. "$root\lib\render.ps1"

function New-ValidConfig {
    @{
        SERVER_USER       = 'yourname'
        PASSWORD_HASH     = '$6$saltsalt$abcdefghijklmnopqrstuvwxyz./0123456789'
        TIMEZONE          = 'America/Chicago'
        TAILSCALE_AUTHKEY = ''
        BATTERY_START     = '60'
        BATTERY_STOP      = '80'
    }
}

Describe 'Read-EnvFile' {
    It 'reads KEY=VALUE lines, skips comments and blanks, keeps $ and = in values' {
        $path = Join-Path $TestDrive 'test.env'
        Set-Content -LiteralPath $path -Value @(
            '# a comment',
            '',
            'A=1',
            'HASH=$6$salt$x=y'
        )
        $values = Read-EnvFile $path
        $values['A'] | Should Be '1'
        $values['HASH'] | Should Be '$6$salt$x=y'
        $values.Count | Should Be 2
    }

    It 'throws on a line without =' {
        $path = Join-Path $TestDrive 'bad.env'
        Set-Content -LiteralPath $path -Value 'NOEQUALS'
        { Read-EnvFile $path } | Should Throw
    }
}

Describe 'Expand-Template' {
    It 'replaces every placeholder' {
        Expand-Template 'host={{H}} user={{U}} again={{H}}' @{ H = 'x1'; U = 'me' } |
            Should Be 'host=x1 user=me again=x1'
    }

    It 'throws naming the missing key' {
        { Expand-Template '{{H}} {{MISSING}}' @{ H = 'x1' } } | Should Throw 'MISSING'
    }

    It 'allows an empty value' {
        Expand-Template 'key={{K}}' @{ K = '' } | Should Be 'key='
    }

    It 'rejects values with quotes or newlines' {
        { Expand-Template '{{K}}' @{ K = "it's" } } | Should Throw
        { Expand-Template '{{K}}' @{ K = 'say "hi"' } } | Should Throw
        { Expand-Template '{{K}}' @{ K = "a`nb" } } | Should Throw
    }
}

Describe 'Test-ServerConfig' {
    It 'accepts a valid config' {
        { Test-ServerConfig (New-ValidConfig) } | Should Not Throw
    }

    It 'rejects a missing key' {
        $c = New-ValidConfig; $c.Remove('SERVER_USER')
        { Test-ServerConfig $c } | Should Throw 'SERVER_USER'
    }

    It 'rejects a battery start that is not below the stop' {
        $c = New-ValidConfig; $c.BATTERY_START = '60'; $c.BATTERY_STOP = '20'
        { Test-ServerConfig $c } | Should Throw 'BATTERY'
    }

    It 'rejects a password that is not a SHA-512 crypt hash' {
        $c = New-ValidConfig; $c.PASSWORD_HASH = 'plaintext'
        { Test-ServerConfig $c } | Should Throw 'PASSWORD_HASH'
    }

    It 'rejects non-numeric or out-of-range battery values' {
        $c = New-ValidConfig; $c.BATTERY_STOP = 'eighty'
        { Test-ServerConfig $c } | Should Throw 'BATTERY'
        $c = New-ValidConfig; $c.BATTERY_STOP = '120'
        { Test-ServerConfig $c } | Should Throw 'BATTERY'
    }

    It 'rejects an invalid user name' {
        $c = New-ValidConfig; $c.SERVER_USER = 'Nadeem Khan'
        { Test-ServerConfig $c } | Should Throw 'SERVER_USER'
    }

    It 'no longer needs a server name (each server names itself)' {
        $RequiredKeys -contains 'SERVER_HOSTNAME' | Should Be $false
    }
}

Describe 'ConvertTo-PasswordHash' {
    It 'returns a SHA-512 crypt hash, different each time (random salt)' {
        $a = ConvertTo-PasswordHash 'correct horse'
        $b = ConvertTo-PasswordHash 'correct horse'
        $a | Should Match '^\$6\$[^$]+\$[A-Za-z0-9./]+$'
        $a | Should Not Be $b
    }

    It 'rejects an empty password' {
        { ConvertTo-PasswordHash '' } | Should Throw
    }

    It 'names the OpenSSL it used and its output when hashing fails' {
        $fake = 'C:\Windows\System32\where.exe'
        { ConvertTo-PasswordHash 'pw' -OpenSsl $fake } | Should Throw $fake
    }
}

Describe 'Wi-Fi config' {
    $psk = 'a' * 64

    It 'still accepts a config without Wi-Fi keys (Wi-Fi off)' {
        { Test-ServerConfig (New-ValidConfig) } | Should Not Throw
    }

    It 'accepts a config with an SSID and a 64-hex key' {
        $c = New-ValidConfig; $c.WIFI_SSID = 'HomeNet'; $c.WIFI_PSK = $psk
        { Test-ServerConfig $c } | Should Not Throw
    }

    It 'rejects an SSID without a valid key' {
        $c = New-ValidConfig; $c.WIFI_SSID = 'HomeNet'
        { Test-ServerConfig $c } | Should Throw 'WIFI_PSK'
        $c.WIFI_PSK = 'tooshort'
        { Test-ServerConfig $c } | Should Throw 'WIFI_PSK'
    }

    It 'Format-EnvFile writes the Wi-Fi keys and they read back' {
        $c = New-ValidConfig; $c.WIFI_SSID = 'HomeNet'; $c.WIFI_PSK = $psk
        $path = Join-Path $TestDrive 'wifi.env'
        Set-Content -LiteralPath $path -Value (Format-EnvFile $c)
        $back = Read-EnvFile $path
        $back.WIFI_SSID | Should Be 'HomeNet'
        $back.WIFI_PSK | Should Be $psk
    }

    It 'Format-EnvFile leaves the Wi-Fi keys out when Wi-Fi is off' {
        (Format-EnvFile (New-ValidConfig)) -join "`n" | Should Not Match 'WIFI'
    }

    It 'example env file mentions the Wi-Fi keys' {
        Get-Content -Raw "$root\server.local.env.example" | Should Match '# WIFI_SSID='
        Get-Content -Raw "$root\server.local.env.example" | Should Match '# WIFI_PSK='
    }
}

Describe 'Wi-Fi input checks' {
    It 'Test-WifiSsid accepts 1-32 UTF-8 bytes only' {
        Test-WifiSsid 'HomeNet' | Should Be $true
        Test-WifiSsid ('a' * 32) | Should Be $true
        Test-WifiSsid ('a' * 33) | Should Be $false
        Test-WifiSsid ('ç½‘' * 11) | Should Be $false   # 33 bytes
        Test-WifiSsid '' | Should Be $false
    }

    It 'Test-WifiPassword accepts 8-63 printable ASCII characters only' {
        Test-WifiPassword 'pass word!' | Should Be $true
        Test-WifiPassword 'short' | Should Be $false
        Test-WifiPassword ('x' * 64) | Should Be $false
        Test-WifiPassword 'pÃ¤ssword1' | Should Be $false
        Test-WifiPassword "tab`there1" | Should Be $false
    }

    It 'env file round-trips non-ASCII values as UTF-8' {
        $c = New-ValidConfig; $c.WIFI_SSID = 'CafÃ©-ç½‘ç»œ'; $c.WIFI_PSK = 'a' * 64
        $path = Join-Path $TestDrive 'utf8.env'
        Set-Content -LiteralPath $path -Value (Format-EnvFile $c) -Encoding UTF8
        (Read-EnvFile $path).WIFI_SSID | Should Be 'CafÃ©-ç½‘ç»œ'
    }

    It 'setup.ps1 saves the env file as UTF-8' {
        Get-Content -Raw "$root\setup.ps1" | Should Match 'Set-Content[^\r\n]*-Encoding UTF8'
    }
}

Describe 'ConvertTo-WifiPsk' {
    It 'matches the IEEE 802.11i test vector' {
        ConvertTo-WifiPsk 'IEEE' 'password' | Should Be 'f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e'
    }

    It 'rejects passwords shorter than 8 or longer than 63 characters' {
        { ConvertTo-WifiPsk 'IEEE' 'short' } | Should Throw '8-63'
        { ConvertTo-WifiPsk 'IEEE' ('x' * 64) } | Should Throw '8-63'
    }

    It 'accepts 8 and 63 characters' {
        { ConvertTo-WifiPsk 'IEEE' ('x' * 8) } | Should Not Throw
        { ConvertTo-WifiPsk 'IEEE' ('x' * 63) } | Should Not Throw
    }
}

Describe 'Get-WifiSsidFromNetsh' {
    It 'returns the SSID, not the BSSID' {
        $text = @(
            '    Name                   : Wi-Fi',
            '    State                  : connected',
            '    SSID                   : My Home Net',
            '    BSSID                  : aa:bb:cc:dd:ee:ff',
            '    Signal                 : 90%'
        )
        Get-WifiSsidFromNetsh $text | Should Be 'My Home Net'
    }

    It 'returns an empty string when disconnected' {
        $text = @('    Name                   : Wi-Fi', '    State                  : disconnected')
        Get-WifiSsidFromNetsh $text | Should Be ''
    }

    It 'returns an empty string when there is no Wi-Fi adapter' {
        Get-WifiSsidFromNetsh @('There is no wireless interface on the system.') | Should Be ''
    }
}

Describe 'Get-LocalIanaTimeZone' {
    It 'detects this PC''s time zone as an IANA name that maps back to the same Windows zone' {
        $iana = Get-LocalIanaTimeZone
        $iana | Should Match '^[A-Za-z_]+/[A-Za-z0-9_+\-/]+$'
        ConvertTo-WindowsTimeZone $iana | Should Be (Get-TimeZone).Id
    }

    It 'falls back to Etc/UTC when a Windows zone has no IANA match' {
        ConvertTo-IanaTimeZone 'Not A Real Zone' | Should Be 'Etc/UTC'
    }
}

Describe 'Reset-UsbDisk' {
    Mock Clear-Disk {}
    Mock Initialize-Disk {}
    Mock Set-Disk {}

    It 'wipes an MBR disk without initializing it again (Windows keeps MBR after a wipe)' {
        Mock Get-Disk { [pscustomobject]@{ PartitionStyle = 'MBR' } }
        Reset-UsbDisk 1
        Assert-MockCalled Clear-Disk -Times 1 -Exactly -Scope It
        Assert-MockCalled Initialize-Disk -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-Disk -Times 0 -Exactly -Scope It
    }

    It 'initializes a blank (RAW) disk as MBR without wiping it' {
        Mock Get-Disk { [pscustomobject]@{ PartitionStyle = 'RAW' } }
        Reset-UsbDisk 1
        Assert-MockCalled Clear-Disk -Times 0 -Exactly -Scope It
        Assert-MockCalled Initialize-Disk -Times 1 -Exactly -Scope It -ParameterFilter { $PartitionStyle -eq 'MBR' }
    }

    It 'converts a GPT disk to MBR after wiping it' {
        Mock Get-Disk { [pscustomobject]@{ PartitionStyle = 'GPT' } }
        Reset-UsbDisk 1
        Assert-MockCalled Clear-Disk -Times 1 -Exactly -Scope It
        Assert-MockCalled Set-Disk -Times 1 -Exactly -Scope It -ParameterFilter { $PartitionStyle -eq 'MBR' }
    }
}

Describe 'Format-EnvFile' {
    It 'writes a file that reads back to the same valid config' {
        $config = New-ValidConfig
        $path = Join-Path $TestDrive 'out.env'
        Set-Content -LiteralPath $path -Value (Format-EnvFile $config)
        $back = Read-EnvFile $path
        foreach ($k in $config.Keys) { $back[$k] | Should Be $config[$k] }
        { Test-ServerConfig $back } | Should Not Throw
    }
}

Describe 'Repo files' {
    It 'autoinstall template renders fully from a valid config' {
        $out = Expand-Template (Get-Content -Raw "$root\autoinstall.template.yaml") (New-ValidConfig)
        $out | Should Not Match '\{\{'
        $out | Should Not Match 'SERVER_HOSTNAME'
        $out | Should Match '^#cloud-config'
        $out | Should Match ([regex]::Escape('password: "$6$saltsalt$abcdefghijklmnopqrstuvwxyz./0123456789"'))
    }

    It 'Write-LfFile writes LF endings and no BOM' {
        $path = Join-Path $TestDrive 'lf.txt'
        Write-LfFile $path "a`r`nb`r`n"
        $bytes = [IO.File]::ReadAllBytes($path)
        ($bytes -join ',') | Should Be '97,10,98,10'
    }

    It 'server.env template renders fully from a valid config' {
        $out = Expand-Template (Get-Content -Raw "$root\server-setup\server.env.template") (New-ValidConfig)
        $out | Should Not Match '\{\{'
        $out | Should Match "SERVER_USER='yourname'"
    }

    It 'example env file has every key the config needs' {
        $example = Read-EnvFile "$root\server.local.env.example"
        foreach ($key in (New-ValidConfig).Keys) { $example.ContainsKey($key) | Should Be $true }
    }

    It 'Wi-Fi template renders fully and holds the SSID and key' {
        $c = New-ValidConfig; $c.WIFI_SSID = 'HomeNet'; $c.WIFI_PSK = 'a' * 64
        $out = Expand-WifiTemplate (Get-Content -Raw "$root\server-setup\wifi.yaml.template") $c
        $out | Should Match "'HomeNet':"
        $out | Should Match ('a' * 64)
        $out | Should Match 'dhcp4: true'
        $out | Should Match 'optional: true'
        $out | Should Not Match '\{\{'
    }

    It 'Wi-Fi template keeps awkward SSIDs exactly, in single quotes' {
        $tpl = Get-Content -Raw "$root\server-setup\wifi.yaml.template"
        $cases = @{
            "Bob's Wi-Fi" = "'Bob''s Wi-Fi':"
            'a\b'         = "'a\b':"
            'x # y'       = "'x # y':"
            'a: b'        = "'a: b':"
            ' lead'       = "' lead':"
            '"quoted"'    = "'""quoted""':"
        }
        foreach ($ssid in $cases.Keys) {
            $c = New-ValidConfig; $c.WIFI_SSID = $ssid; $c.WIFI_PSK = 'a' * 64
            (Expand-WifiTemplate $tpl $c).Contains("        $($cases[$ssid])") | Should Be $true
        }
    }

    It 'autoinstall installs wpasupplicant and runs install-wifi.sh' {
        $t = Get-Content -Raw "$root\autoinstall.template.yaml"
        $t | Should Match 'wpasupplicant'
        $t | Should Match 'install-wifi\.sh'
    }

    It 'build-usb.ps1 writes the Wi-Fi file only when WIFI_SSID is set and copies install-wifi.sh' {
        $b = Get-Content -Raw "$root\build-usb.ps1"
        $b | Should Match 'WIFI_SSID'
        $b | Should Match '60-wifi\.yaml'
        $b | Should Match 'install-wifi\.sh'
    }

    It 'Linux files use LF line endings' {
        foreach ($f in 'server-setup\firstboot.sh', 'server-setup\make-hostname.sh', 'server-setup\install-wifi.sh', 'server-setup\wifi.yaml.template', 'server-setup\server-firstboot.service') {
            [IO.File]::ReadAllText("$root\$f") | Should Not Match "`r"
        }
    }

    It 'build-usb.ps1 does not use $PSScriptRoot in parameter defaults (empty in the elevated window)' {
        $ast = [Management.Automation.Language.Parser]::ParseFile("$root\build-usb.ps1", [ref]$null, [ref]$null)
        $ast.ParamBlock.Extent.Text | Should Not Match 'PSScriptRoot'
    }

    It 'setup.ps1 passes the config file path to build-usb.ps1' {
        Get-Content -Raw "$root\setup.ps1" | Should Match "'-EnvFile'"
    }

    It 'firstboot.sh is valid bash' {
        $bash = 'C:\Program Files\Git\bin\bash.exe'
        & $bash -n "$root\server-setup\firstboot.sh"
        $LASTEXITCODE | Should Be 0
        & $bash -n "$root\server-setup\make-hostname.sh"
        $LASTEXITCODE | Should Be 0
        & $bash -n "$root\server-setup\install-wifi.sh"
        $LASTEXITCODE | Should Be 0
    }

    It 'firstboot.sh stops with a clear message when there is no internet' {
        $bash = 'C:\Program Files\Git\bin\bash.exe'
        $dir = (Join-Path $TestDrive 'nonet') -replace '\\', '/'
        New-Item -ItemType Directory -Force $dir | Out-Null
        Write-LfFile "$dir/server.env" "SERVER_USER='x'`n"
        $script = "$root\server-setup\firstboot.sh" -replace '\\', '/'
        # A stub getent that fails (exit 2 = name not found) comes first on PATH.
        $stub = (Join-Path $TestDrive 'stub') -replace '\\', '/'
        New-Item -ItemType Directory -Force $stub | Out-Null
        Write-LfFile "$stub/getent" "#!/bin/sh`nexit 2`n"
        $stubU = '/' + $stub.Substring(0, 1).ToLower() + $stub.Substring(2)   # C:/x -> /c/x for Git Bash
        $out = & $bash -c "export PATH='$stubU':`$PATH; SETUP_DIR='$dir' NET_CHECK_HOST='no-such-host.invalid' NET_WAIT_SECONDS=0 bash '$script'"
        $LASTEXITCODE | Should Be 1
        ($out -join ' ') | Should Match 'No internet: plug in Ethernet or check the Wi-Fi settings'
    }

    It 'firstboot.sh exits cleanly when setup already ran (no server.env)' {
        $bash = 'C:\Program Files\Git\bin\bash.exe'
        $dir = (Join-Path $TestDrive 'setup') -replace '\\', '/'
        New-Item -ItemType Directory -Force $dir | Out-Null
        $script = "$root\server-setup\firstboot.sh" -replace '\\', '/'
        $out = & $bash -c "SETUP_DIR='$dir' bash '$script'"
        $LASTEXITCODE | Should Be 0
        ($out -join ' ') | Should Match 'already'
    }
}

Describe 'install-wifi.sh' {
    # Runs the script against fake /cdrom, /sys/class/net and /target folders.
    function Invoke-InstallWifi([bool]$WithFile, [string[]]$Wireless) {
        $dir = Join-Path $TestDrive ([guid]::NewGuid())
        $d = $dir -replace '\\', '/'
        New-Item -ItemType Directory "$dir\cdrom", "$dir\net\eth0", "$dir\target\etc\netplan" | Out-Null
        foreach ($i in $Wireless) { New-Item -ItemType Directory "$dir\net\$i\wireless" | Out-Null }
        if ($WithFile) { Write-LfFile "$dir\cdrom\60-wifi.yaml" "iface: __WIFI_IFACE__`n" }
        $script = "$root\server-setup\install-wifi.sh" -replace '\\', '/'
        $out = & 'C:\Program Files\Git\bin\bash.exe' -c "WIFI_SRC='$d/cdrom/60-wifi.yaml' NET_DIR='$d/net' WIFI_DEST='$d/target/etc/netplan/60-wifi.yaml' bash '$script'"
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = "$out"; Dest = "$dir\target\etc\netplan\60-wifi.yaml" }
    }

    It 'does nothing when the stick has no Wi-Fi file' {
        $r = Invoke-InstallWifi $false @('wlan0')
        $r.Code | Should Be 0
        Test-Path $r.Dest | Should Be $false
    }

    It 'writes the netplan file with the wireless interface name' {
        $r = Invoke-InstallWifi $true @('wlp2s0')
        $r.Code | Should Be 0
        (Get-Content -Raw $r.Dest).Trim() | Should Be 'iface: wlp2s0'
    }

    It 'prints a note and exits 0 when there is no wireless interface' {
        $r = Invoke-InstallWifi $true @()
        $r.Code | Should Be 0
        $r.Out | Should Match 'No Wi-Fi'
        Test-Path $r.Dest | Should Be $false
    }
}

Describe 'make-hostname.sh' {
    # Runs the script against a fake /sys/class/dmi/id folder and machine-id file.
    function Invoke-MakeHostname([hashtable]$Dmi, [string]$MachineId = '0123456789abcdef0123456789abef99') {
        $dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $dir | Out-Null
        foreach ($k in $Dmi.Keys) { Write-LfFile (Join-Path $dir $k) "$($Dmi[$k])`n" }
        Write-LfFile (Join-Path $dir 'machine-id') "$MachineId`n"
        $d = $dir -replace '\\', '/'
        $script = "$root\server-setup\make-hostname.sh" -replace '\\', '/'
        $out = & 'C:\Program Files\Git\bin\bash.exe' -c "DMI_DIR='$d' MACHINE_ID_FILE='$d/machine-id' bash '$script'"
        if ($LASTEXITCODE) { throw "make-hostname.sh exited with $LASTEXITCODE" }
        "$out".Trim()
    }

    It 'uses the model from product_version (Lenovo) and the last 4 of the serial' {
        Invoke-MakeHostname @{ product_version = 'ThinkPad X1 Carbon 5th'; product_name = '20HRCTO1WW'; product_serial = 'PF0ABC12' } |
            Should Be 'thinkpad-x1-carbon-5th-bc12'
    }

    It 'uses product_name when product_version is a placeholder (Dell, HP)' {
        Invoke-MakeHostname @{ product_version = 'Not Specified'; product_name = 'Latitude 7490'; product_serial = '7K2QXYZ' } |
            Should Be 'latitude-7490-qxyz'
    }

    It 'falls back to server-<machine-id> when model and serial are placeholders' {
        Invoke-MakeHostname @{ product_version = '1.0'; product_name = 'To Be Filled By O.E.M.'; product_serial = 'To Be Filled By O.E.M.' } |
            Should Be 'server-ef99'
    }

    It 'keeps long names within the 63-character hostname limit' {
        $name = Invoke-MakeHostname @{ product_name = ('Very Long Model Name ' * 6); product_serial = 'SN1234' }
        $name.Length | Should BeLessThan 64
        $name | Should Match '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
        $name | Should Match '-1234$'
    }
}