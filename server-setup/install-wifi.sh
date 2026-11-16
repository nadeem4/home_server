#!/usr/bin/env bash
# Runs during the install (autoinstall late-command). If the stick has a Wi-Fi file, puts it
# on the new system as a netplan config for this laptop's wireless card.
# Never fails the install: without Wi-Fi the server still works over Ethernet.
set -u

WIFI_SRC="${WIFI_SRC:-/cdrom/server-setup/60-wifi.yaml}"
NET_DIR="${NET_DIR:-/sys/class/net}"
WIFI_DEST="${WIFI_DEST:-/target/etc/netplan/60-wifi.yaml}"

[ -f "$WIFI_SRC" ] || exit 0

iface=""
for d in "$NET_DIR"/*; do
    if [ -d "$d/wireless" ]; then iface="$(basename "$d")"; break; fi
done
if [ -z "$iface" ]; then
    echo "No Wi-Fi card found: skipping Wi-Fi setup."
    exit 0
fi

mkdir -p "$(dirname "$WIFI_DEST")"
sed "s/__WIFI_IFACE__/$iface/" "$WIFI_SRC" > "$WIFI_DEST"
chmod 600 "$WIFI_DEST"
echo "Wi-Fi set up on $iface."
exit 0
