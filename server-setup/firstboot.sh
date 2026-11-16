#!/usr/bin/env bash
# One-time setup that turns a fresh Ubuntu Server install into a home server.
# Run once on first boot by server-firstboot.service. Log: /var/log/server-firstboot.log
# If it fails, fix the cause and re-run: sudo /opt/server-setup/firstboot.sh
set -euo pipefail

SETUP_DIR="${SETUP_DIR:-/opt/server-setup}"
if [ ! -f "$SETUP_DIR/server.env" ]; then
    echo "Setup already ran (no $SETUP_DIR/server.env). Nothing to do."
    exit 0
fi
# shellcheck source=/dev/null
source "$SETUP_DIR/server.env"
export DEBIAN_FRONTEND=noninteractive

# Wait for internet (Wi-Fi can take a minute to connect); the service retries on the next boot.
NET_CHECK_HOST="${NET_CHECK_HOST:-archive.ubuntu.com}"
NET_WAIT_SECONDS="${NET_WAIT_SECONDS:-300}"
waited=0
until getent hosts "$NET_CHECK_HOST" > /dev/null; do
    if [ "$waited" -ge "$NET_WAIT_SECONDS" ]; then
        echo "No internet: plug in Ethernet or check the Wi-Fi settings"
        exit 1
    fi
    sleep 5
    waited=$((waited + 5))
done
# Wait for the dpkg lock (apt-daily may hold it on first boot); keep existing config files.
APT=(apt-get -y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold)

echo "== $(date) first-boot setup starting"

echo "-- server name, from this laptop's model and serial number"
SERVER_NAME="$("$SETUP_DIR/make-hostname.sh")"
hostnamectl set-hostname "$SERVER_NAME"
if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $SERVER_NAME/" /etc/hosts
else
    echo "127.0.1.1 $SERVER_NAME" >> /etc/hosts
fi
# Stop cloud-init from setting the installer's temporary name back on a later boot.
mkdir -p /etc/cloud/cloud.cfg.d
echo 'preserve_hostname: true' > /etc/cloud/cloud.cfg.d/99-keep-hostname.cfg
echo "Server name: $SERVER_NAME"

echo "-- packages"
"${APT[@]}" update
"${APT[@]}" full-upgrade
"${APT[@]}" install curl tlp ufw unattended-upgrades docker.io docker-compose-v2
# No recommends: they pull in NetworkManager, which clashes with the server's netplan networking.
"${APT[@]}" install --no-install-recommends cockpit

echo "-- keep running with the lid closed"
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/10-lid.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF

echo "-- battery: charge between ${BATTERY_START}% and ${BATTERY_STOP}%"
mkdir -p /etc/tlp.d
cat > /etc/tlp.d/90-battery.conf <<EOF
START_CHARGE_THRESH_BAT0=${BATTERY_START}
STOP_CHARGE_THRESH_BAT0=${BATTERY_STOP}
EOF
systemctl enable tlp

echo "-- screen off after 60 seconds"
mkdir -p /etc/default/grub.d
cat > /etc/default/grub.d/90-consoleblank.cfg <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT consoleblank=60"
EOF
update-grub

echo "-- automatic security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

echo "-- docker"
systemctl enable docker
usermod -aG docker "$SERVER_USER"

echo "-- cockpit (web dashboard on port 9090)"
systemctl enable cockpit.socket

echo "-- tailscale"
curl -fsSL https://tailscale.com/install.sh | sh
if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    tailscale up --auth-key="$TAILSCALE_AUTHKEY" --ssh --hostname="$SERVER_NAME"
else
    echo "No TAILSCALE_AUTHKEY given: run 'sudo tailscale up --ssh' once to join your tailnet."
fi

echo "-- firewall: everything over Tailscale; Cockpit also from the home network"
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
    ufw allow from "$net" to any port 9090 proto tcp
done
ufw --force enable

echo "-- cleanup: remove the Tailscale key from disk, mark done, reboot"
shred -u "$SETUP_DIR/server.env"
touch "$SETUP_DIR/.done"
echo "== $(date) first-boot setup finished"
systemctl --no-block reboot
