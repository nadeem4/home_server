#!/usr/bin/env bash
# Prints a server name made from this machine's model and serial number,
# e.g. thinkpad-x1-carbon-5th-bc12, so one USB stick can set up any number of laptops.
# Falls back to server-<last 4 of the machine id> when the firmware gives no useful info.
set -euo pipefail

DMI_DIR="${DMI_DIR:-/sys/class/dmi/id}"
MACHINE_ID_FILE="${MACHINE_ID_FILE:-/etc/machine-id}"

# Lowercase, anything other than letters and digits becomes one dash, no dash at either end.
slug() { tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }
read_slug() { cat "$1" 2>/dev/null | slug || true; }
# Values firmware uses when it has nothing real to say, after slug(); also bare version numbers.
is_placeholder() {
    [[ "$1" =~ ^(none|default-string|not-specified|not-applicable|to-be-filled-by-o-e-m|system-product-name|system-version|system-serial-number|[0-9-]*)$ ]]
}

# Model: Lenovo puts it in product_version, most other brands in product_name.
model=""
for f in product_version product_name; do
    v="$(read_slug "$DMI_DIR/$f")"
    if ! is_placeholder "$v"; then model="$v"; break; fi
done
[ -n "$model" ] || model="server"

# Suffix: last 4 characters of the serial number, or of the machine id.
serial="$(read_slug "$DMI_DIR/product_serial")"
if is_placeholder "$serial"; then serial="$(read_slug "$MACHINE_ID_FILE")"; fi
serial="${serial//-/}"
suffix="${serial: -4}"

# Hostnames are at most 63 characters: shorten the model, keeping the suffix.
model="$(echo "${model:0:58}" | sed -E 's/-+$//')"
echo "$model-$suffix"
