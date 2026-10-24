#!/usr/bin/env bash
# Remove nvidia-compute-toggle's boot policy and CLI.
# The NVIDIA driver packages and the user's shell aliases are left alone.
set -euo pipefail

CONFIG=/etc/nvidia-compute-toggle.conf
UNIT=/etc/systemd/system/nvidia-compute-off.service
MODPROBE=/etc/modprobe.d/90-nvidia-compute-off.conf
KERNEL_CMDLINE=/etc/kernel/cmdline
BINDIR=/usr/local/bin
DATADIR=/usr/share/nvidia-compute-toggle
DOCDIR=/usr/share/doc/nvidia-compute-toggle
HELPER=/usr/local/libexec/nvidia-compute-helper
SUDOERS=/etc/sudoers.d/nvidia-compute-toggle
EXT_UUID=nvidia-compute-toggle@lukas

DGPU_PCI=""

usage() {
    cat <<'EOF'
Usage: sudo ./uninstall.sh

Removes:
  - nvidia-compute-off.service
  - /etc/nvidia-compute-toggle.conf
  - /etc/modprobe.d/90-nvidia-compute-off.conf
  - the nouveau/nova_core kernel arguments added by the installer
  - /usr/local/bin/nvidia-compute and the installed docs/aliases

It does not remove the NVIDIA driver packages or your ~/.aliases.
EOF
}

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) die "unknown option: $1 (try --help)" ;;
esac

[ "$(id -u)" -eq 0 ] || die "must run as root: sudo $0"

if [ -r "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG"
fi

step "Disabling and removing $UNIT"
systemctl disable --now nvidia-compute-off.service 2>/dev/null || true
rm -f "$UNIT"
systemctl daemon-reload
info "removed"

step "Removing configuration and modprobe blacklist"
rm -f "$CONFIG" "$MODPROBE"
info "removed"

step "Removing kernel arguments"
for arg in \
    "rd.driver.blacklist=nouveau,nova_core" \
    "modprobe.blacklist=nouveau,nova_core" \
    "rd.driver.blacklist=nouveau" \
    "modprobe.blacklist=nouveau"; do
    grubby --update-kernel=ALL --remove-args="$arg" 2>/dev/null || true
done
info "existing BLS entries updated"

if [ -f "$KERNEL_CMDLINE" ]; then
    cp -a "$KERNEL_CMDLINE" "${KERNEL_CMDLINE}.bak"
    sed -i \
        -e 's/ *rd\.driver\.blacklist=nouveau,nova_core//g' \
        -e 's/ *modprobe\.blacklist=nouveau,nova_core//g' \
        -e 's/ *rd\.driver\.blacklist=nouveau//g' \
        -e 's/ *modprobe\.blacklist=nouveau//g' \
        "$KERNEL_CMDLINE"
    info "cleaned $KERNEL_CMDLINE (backup: ${KERNEL_CMDLINE}.bak)"
fi

step "Unmasking NVIDIA helper services"
for unit in nvidia-fallback.service nvidia-persistenced.service nvidia-powerd.service; do
    systemctl unmask "$unit" 2>/dev/null || true
done
info "done"

step "Removing CLI and installed documentation"
rm -f "$BINDIR/nvidia-compute"
rm -rf "$DATADIR" "$DOCDIR"
info "removed"

step "Removing GNOME extension, helper, and sudoers rule"
target_user="${SUDO_USER:-}"
if [ -n "$target_user" ] && [ "$target_user" != "root" ]; then
    target_home=$(getent passwd "$target_user" | cut -d: -f6)
    target_uid=$(id -u "$target_user")
    if [ -n "$target_home" ] && [ "$target_home" != "/" ]; then
        ext_dir="$target_home/.local/share/gnome-shell/extensions/$EXT_UUID"
        if command -v gnome-extensions >/dev/null 2>&1 &&
           [ -d "/run/user/$target_uid" ]; then
            sudo -u "$target_user" \
                env XDG_RUNTIME_DIR="/run/user/$target_uid" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$target_uid/bus" \
                    gnome-extensions disable "$EXT_UUID" 2>/dev/null || true
        fi
        rm -rf "$ext_dir"
        info "removed extension for $target_user"
    else
        warn "could not resolve home for $target_user; extension not removed"
    fi
else
    warn "SUDO_USER not set; extension files in user homes were not removed"
fi

rm -f "$HELPER" "$SUDOERS"
info "removed helper and sudoers rule"

step "Rescanning the PCI bus"
if [ -n "$DGPU_PCI" ]; then
    echo 1 >/sys/bus/pci/rescan 2>/dev/null || true
    info "requested rescan for $DGPU_PCI"
else
    info "no recorded PCI address; reboot to bring the GPU back"
fi

step "Done"
cat <<'EOF'
nvidia-compute-toggle has been removed.

The NVIDIA driver packages and the dGPU itself are untouched.  Reboot to
return to a normal boot without the rail-off unit.  If nouveau still does not
load, rebuild the initramfs once with:

    sudo dracut --force
    sudo reboot

Only do that after checking /boot has free space.
EOF
