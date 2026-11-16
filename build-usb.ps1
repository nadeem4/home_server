<#
.SYNOPSIS
  Turns a USB stick into an Ubuntu Server installer that sets the server up by itself.
  ERASES THE USB STICK. Run in an Administrator PowerShell.

.EXAMPLE
  Get-Disk                          # find the USB stick's disk number
  powershell -ExecutionPolicy Bypass -File .\build-usb.ps1 -DiskNumber 1
#>
param(
    [Parameter(Mandatory)][int]$DiskNumber,
    # Ubuntu Server point release. Newer ones live at releases.ubuntu.com/resolute.
    [string]$UbuntuVersion = '26.04.1',
    [string]$EnvFile = '',
    [string]$IsoPath = ''
)
$ErrorActionPreference = 'Stop'
# Set here, not as a parameter default: $PSScriptRoot can be empty there in an elevated window.
if (-not $EnvFile) { $EnvFile = Join-Path $PSScriptRoot 'server.local.env' }
. "$PSScriptRoot\lib\render.ps1"

$IsoName = "ubuntu-$UbuntuVersion-live-server-amd64.iso"
if (-not $IsoPath) { $IsoPath = "$env:USERPROFILE\Downloads\$IsoName" }
# Superseded point releases move to old-releases.ubuntu.com.
$ReleaseUrl = 'https://releases.ubuntu.com/resolute'
curl.exe -fsIL -o NUL "$ReleaseUrl/$IsoName"
if ($LASTEXITCODE) { $ReleaseUrl = 'https://old-releases.ubuntu.com/releases/resolute' }

# 1. Administrator rights are needed to partition the disk.
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this in an Administrator PowerShell.'
}

# 2. Check the config and fill the templates before touching anything.
if (-not (Test-Path $EnvFile)) { throw "No $EnvFile. Copy server.local.env.example to it and fill it in." }
$values = Read-EnvFile $EnvFile
Test-ServerConfig $values
$autoinstall = Expand-Template (Get-Content -Raw "$PSScriptRoot\autoinstall.template.yaml") $values
$serverEnv = Expand-Template (Get-Content -Raw "$PSScriptRoot\server-setup\server.env.template") $values

# 3. Download the ISO if needed and check it against Ubuntu's published checksum.
if (-not (Test-Path $IsoPath)) {
    Write-Host "Downloading $IsoName (about 3 GB)..."
    curl.exe -fL -o $IsoPath "$ReleaseUrl/$IsoName"
    if ($LASTEXITCODE) { throw 'ISO download failed.' }
}
Write-Host 'Checking the ISO checksum...'
$sums = curl.exe -fsSL "$ReleaseUrl/SHA256SUMS"
$expected = ($sums | Where-Object { $_ -match [regex]::Escape($IsoName) }) -split '\s+' | Select-Object -First 1
if (-not $expected) { throw "No checksum for $IsoName in SHA256SUMS." }
if ((Get-FileHash $IsoPath -Algorithm SHA256).Hash -ne $expected.ToUpper()) {
    throw "Checksum mismatch: delete $IsoPath and run again."
}

# 4. Make sure this is the USB stick, then ask before erasing it.
$disk = Get-Disk -Number $DiskNumber
if ($disk.BusType -ne 'USB') { throw "Disk $DiskNumber is $($disk.BusType), not USB. Refusing." }
if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $DiskNumber is a system disk. Refusing." }
if ($disk.Size -gt 256GB) { throw "Disk $DiskNumber is larger than 256 GB. Refusing." }
if ($disk.Size -lt 9GB) { throw "Disk $DiskNumber is smaller than 9 GB. Use a 16 GB or larger stick." }
$sizeGb = [math]::Round($disk.Size / 1GB, 1)
Write-Host "About to ERASE disk ${DiskNumber}: $($disk.FriendlyName), $sizeGb GB" -ForegroundColor Yellow
if ((Read-Host 'Type ERASE to continue') -ne 'ERASE') { Write-Host 'Stopped. Nothing changed.'; exit 1 }

# 5. Partition: 8 GB FAT32 installer + the rest as exFAT for normal use.
Reset-UsbDisk $DiskNumber
$boot = New-Partition -DiskNumber $DiskNumber -Size 8GB -AssignDriveLetter
Format-Volume -Partition $boot -FileSystem FAT32 -NewFileSystemLabel 'UBUNTU' -Confirm:$false | Out-Null
$data = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $data -FileSystem exFAT -NewFileSystemLabel 'DATA' -Confirm:$false | Out-Null
$usb = "$((Get-Partition -DiskNumber $DiskNumber -PartitionNumber $boot.PartitionNumber).DriveLetter):\"

# 6. Copy the ISO's files onto the FAT32 partition (UEFI boots from it directly).
Write-Host "Copying Ubuntu to $usb..."
$mount = Mount-DiskImage -ImagePath $IsoPath -PassThru
try {
    $iso = "$(($mount | Get-Volume).DriveLetter):\"
    robocopy $iso $usb /E /XJ /NFL /NDL /NP /NJH | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copy failed (robocopy $LASTEXITCODE)." }
} finally {
    Dismount-DiskImage -ImagePath $IsoPath | Out-Null
}

# 7. Add the autoinstall file and the first-boot setup.
Write-LfFile "$usb\autoinstall.yaml" $autoinstall
New-Item -ItemType Directory -Force "$usb\server-setup" | Out-Null
Write-LfFile "$usb\server-setup\server.env" $serverEnv
foreach ($f in 'firstboot.sh', 'make-hostname.sh', 'server-firstboot.service') {
    Write-LfFile "$usb\server-setup\$f" (Get-Content -Raw "$PSScriptRoot\server-setup\$f")
}

Write-Host "Done. The USB stick is ready: plug it into the laptop, press F12 at power-on and pick it." -ForegroundColor Green
