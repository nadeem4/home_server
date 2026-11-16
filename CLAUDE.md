# home_server

Turns old laptops into Ubuntu Server home servers from one USB stick built on Windows
(autoinstall + first-boot setup: Docker, Tailscale, Cockpit, firewall, battery limit).

## Commands
- Setup: Git for Windows (for openssl and bash); Pester 3.4 ships with Windows PowerShell
- Test: `powershell -ExecutionPolicy Bypass -Command "Invoke-Pester -Path .\tests"`
- Run: `powershell -ExecutionPolicy Bypass -File .\setup.ps1` (builds the USB stick)

## Layout
- `setup.ps1`: the wizard; asks settings, writes server.local.env, starts build-usb.ps1
- `build-usb.ps1`: downloads and checks the ISO, partitions the stick, copies files
- `lib/render.ps1`: config reading, checks, templates, password hash, time zone, disk reset
- `autoinstall.template.yaml`: Ubuntu autoinstall config with {{KEY}} placeholders
- `server-setup/`: runs on the server: firstboot.sh, make-hostname.sh, the systemd unit
- `tests/render.Tests.ps1`: all tests (PowerShell, plus bash scripts via Git Bash)

## Conventions
- Never commit server.local.env (password hash, Tailscale key) or anything personal.
- Files that go to the server use LF endings (.gitattributes, Write-LfFile).
- No hard-coded machine values: server name and time zone are detected.
