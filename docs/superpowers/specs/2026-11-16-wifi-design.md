# Wi-Fi support (design)

## Why
Many old laptops have no Ethernet port, and users may not have an adapter yet. Today the
server only configures wired networking, so first-boot setup fails with no internet
("Temporary failure resolving archive.ubuntu.com"). Users should be able to install over
Wi-Fi and switch to Ethernet later, or keep both.

## Goals
- `setup.ps1` asks for a Wi-Fi network (default: the one this PC is connected to) and its
  password (hidden, typed twice). Enter skips Wi-Fi.
- The server gets both wired (`en*`, DHCP) and Wi-Fi configs. Whichever is connected works;
  wired wins when both are (route metrics).
- First-boot setup waits for internet instead of failing on apt.

## Non-goals / anti-goals
- No Wi-Fi during the install itself (the install works offline from the ISO).
- No interactive Wi-Fi prompt on the server console.
- The Wi-Fi password itself is never stored on disk or on the stick.

## Approaches
- **A (picked):** ask in `setup.ps1` on Windows; store the SSID and the derived WPA2 key
  (PSK); write a netplan Wi-Fi file during the install. Install stays hands-off.
- B: `interactive-sections: [network]`, so the installer shows its network screen on the
  laptop. Nothing stored, but the install is no longer hands-off.
- Rejected: first-boot console prompt for Wi-Fi (fragile, more code).

## Design
- `server.local.env`: new optional keys `WIFI_SSID`, `WIFI_PSK` (64 lowercase hex). An older
  env file without them still builds (no Wi-Fi). If `WIFI_SSID` is set, `WIFI_PSK` must be 64 hex.
- `lib/render.ps1`:
  - `ConvertTo-WifiPsk($Ssid, $Password)`: PBKDF2-HMAC-SHA1, salt = SSID (UTF-8), 4096
    iterations, 32 bytes, lowercase hex. Password must be 8-63 characters. Test vector
    (IEEE 802.11i): "password" + "IEEE" = f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e.
  - Parse the connected SSID from `netsh wlan show interfaces` (the `SSID :` line, not `BSSID`).
- `server-setup/wifi.yaml.template`: netplan `wifis` with a placeholder interface name,
  `dhcp4: true`, the SSID and the PSK as `password`.
- `build-usb.ps1`: when `WIFI_SSID` is set, writes the rendered file to the stick.
- `autoinstall.template.yaml`: installs `wpasupplicant` (it is in the ISO's pool, so it works
  offline); a late-command runs `server-setup/install-wifi.sh`, which, if the Wi-Fi file is on
  the stick, finds the wireless interface (`/sys/class/net/*/wireless`), writes
  `/target/etc/netplan/60-wifi.yaml` with mode 600, and never fails the install.
- `firstboot.sh`: waits up to 5 minutes for DNS to resolve the Ubuntu archive; if it never
  does, logs "No internet: plug in Ethernet or check the Wi-Fi settings" and exits non-zero
  (the service runs again on the next boot).
- README: Wi-Fi or Ethernet, switching later, the WPA3-only limitation.

## Limits
- WPA3-only networks do not accept a derived PSK. WPA2 and WPA2/WPA3 mixed networks work.
- Only verified on real hardware after the next install.
