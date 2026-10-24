#!/usr/bin/env bash
# Install the nvidia-compute-toggle boot-time "off" policy and CLI.
#
# This project manages the dGPU power state only.  It does not install the
# NVIDIA driver, CUDA, or PyTorch.  See docs/driver-setup.md.
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG=/etc/nvidia-compute-toggle.conf
UNIT=/etc/systemd/system/nvidia-compute-off.service
MODPROBE=/etc/modprobe.d/90-nvidia-compute-off.conf
KERNEL_CMDLINE=/etc/kernel/cmdline
KARGS="rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core"
BINDIR=/usr/local/bin
DATADIR=/usr/share/nvidia-compute-toggle
DOCDIR=/usr/share/doc/nvidia-compute-toggle
HELPER=/usr/local/libexec/nvidia-compute-helper
SUDOERS=/etc/sudoers.d/nvidia-compute-toggle
EXT_UUID=nvidia-compute-toggle@lukas

CHECK_ONLY=0
START_NOW=1
WITH_EXTENSION=0

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [OPTIONS]

Options:
  --check           Detect the GPU/bridge and driver, print the plan, change nothing.
  --no-start        Install and enable the unit, but do not remove the GPU now.
  --with-extension  Also install the passwordless helper and the GNOME
                    Quick Settings extension for the invoking desktop user.
  -h, --help        Show this help.

Environment:
  DGPU_PCI=0000:01:00.0     Override GPU detection.
  DGPU_BRIDGE=0000:00:01.0  Override parent bridge detection.
  DGPU_NAME="..."           Optional human-readable GPU name.

The installer writes:
  /etc/nvidia-compute-toggle.conf
  /etc/modprobe.d/90-nvidia-compute-off.conf
  /etc/systemd/system/nvidia-compute-off.service
  /usr/local/bin/nvidia-compute
  /usr/share/nvidia-compute-toggle/aliases.sh
  /usr/share/doc/nvidia-compute-toggle/

It also updates the kernel command line for nouveau/nova_core and masks the
NVIDIA helper services that would wake or keep the GPU initialized.
EOF
}

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

rollback_new_unit() {
    systemctl disable --now nvidia-compute-off.service 2>/dev/null || true
    rm -f "$UNIT"
    systemctl daemon-reload 2>/dev/null || true
}

while (($#)); do
    case "$1" in
        --check)          CHECK_ONLY=1 ;;
        --no-start)       START_NOW=0 ;;
        --with-extension) WITH_EXTENSION=1 ;;
        -h|--help)        usage; exit 0 ;;
        *)          die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

for cmd in lspci systemctl modinfo grubby; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done

if [ "$WITH_EXTENSION" -eq 1 ] && [ "$CHECK_ONLY" -eq 0 ]; then
    command -v visudo >/dev/null 2>&1 ||
        die "visudo is required for --with-extension"
fi

if [ "$CHECK_ONLY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    die "must run as root: sudo $0"
fi

detect_gpu() {
    local pci="${DGPU_PCI:-}"
    if [ -z "$pci" ]; then
        pci=$(lspci -Dn 2>/dev/null |
            awk '$2 ~ /^030[0-9]:/ && $3 ~ /^10de:/ {print $1; exit}')
    fi
    # If the GPU is already removed, recover the address from the old
    # nvidia-disable unit so migration works without manual environment vars.
    if [ -z "$pci" ] && [ -f /etc/systemd/system/disable-nvidia.service ]; then
        pci=$(grep -oiE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]' \
            /etc/systemd/system/disable-nvidia.service | head -1 || true)
    fi
    printf '%s\n' "$pci"
}

detect_bridge() {
    local pci="$1" bus bridge f
    bus=${pci#*:}
    bus=${bus%%:*}
    for f in /sys/bus/pci/devices/*/secondary_bus_number; do
        [ -r "$f" ] || continue
        if [ "$(printf '%02x' "$(cat "$f")" 2>/dev/null)" = "$bus" ]; then
            bridge=$(basename "$(dirname "$f")")
            printf '%s\n' "$bridge"
            return 0
        fi
    done
    return 1
}

gpu_present() {
    [ -e "/sys/bus/pci/devices/$1" ]
}

module_license() {
    modinfo -F license nvidia 2>/dev/null || true
}

GPU_PCI=$(detect_gpu)
[ -n "$GPU_PCI" ] || die "no NVIDIA VGA/3D controller found; if the dGPU is already removed, set DGPU_PCI=0000:01:00.0"

if ! [[ "$GPU_PCI" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
    die "invalid PCI address: $GPU_PCI"
fi

GPU_BRIDGE="${DGPU_BRIDGE:-}"
if [ -z "$GPU_BRIDGE" ]; then
    GPU_BRIDGE=$(detect_bridge "$GPU_PCI") || true
fi
[ -n "$GPU_BRIDGE" ] || die "could not determine the parent PCI bridge; set DGPU_BRIDGE=..."

if [ -n "${DGPU_NAME:-}" ]; then
    GPU_NAME="$DGPU_NAME"
elif gpu_present "$GPU_PCI"; then
    GPU_NAME=$(lspci -s "$GPU_PCI" 2>/dev/null | sed 's/^[^ ]* //' || true)
else
    GPU_NAME="NVIDIA dGPU"
fi
[ -n "$GPU_NAME" ] || GPU_NAME="NVIDIA dGPU"

LICENSE=$(module_license)
if [ -z "$LICENSE" ]; then
    DRIVER_STATE="no nvidia module for $(uname -r)"
elif [ "$LICENSE" = "NVIDIA" ]; then
    DRIVER_STATE="proprietary NVIDIA module"
else
    DRIVER_STATE="module license: $LICENSE"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    step "Detection"
    info "GPU PCI:     $GPU_PCI"
    info "GPU name:    $GPU_NAME"
    info "Bridge:      $GPU_BRIDGE"
    if gpu_present "$GPU_PCI"; then
        info "GPU state:   present on the bus"
    else
        info "GPU state:   absent from the bus (address will still be used)"
    fi
    info "Driver:      $DRIVER_STATE"
    info "Config:      $CONFIG"
    info "Unit:        $UNIT"
    info "Modprobe:    $MODPROBE"
    info "CLI:         $BINDIR/nvidia-compute"
    if [ "$WITH_EXTENSION" -eq 1 ]; then
        info "Helper:      $HELPER"
        info "Sudoers:     $SUDOERS"
        info "Extension:   $EXT_UUID (for ${SUDO_USER:-the desktop user})"
    fi
    if [ -z "$LICENSE" ]; then
        warn "install the NVIDIA driver before using 'nvidia-compute on' (see docs/driver-setup.md)"
    elif [[ "$LICENSE" == *"Dual MIT/GPL"* ]]; then
        warn "this is nvidia-open; Pascal needs the proprietary 580xx module"
    fi
    exit 0
fi

step "Detected hardware"
info "GPU:    $GPU_PCI  ($GPU_NAME)"
info "Bridge: $GPU_BRIDGE"
info "Driver: $DRIVER_STATE"

if [ -z "$LICENSE" ]; then
    warn "no nvidia module for $(uname -r); the toggle will install, but CUDA will not work until the driver is installed"
elif [[ "$LICENSE" == *"Dual MIT/GPL"* ]]; then
    warn "nvidia-open is installed; Pascal needs the proprietary 580xx module"
    warn "see docs/driver-setup.md; 'nvidia-compute doctor' will flag this"
fi

if lsmod | awk '{print $1}' | grep -qx nvidia; then
    step "Checking for running CUDA work"
    command -v nvidia-smi >/dev/null 2>&1 ||
        die "the nvidia module is loaded but nvidia-smi is missing; refusing to remove the GPU"
    if ! procs=$(timeout 5 nvidia-smi --query-compute-apps=pid,process_name \
        --format=csv,noheader 2>/dev/null); then
        die "nvidia-smi failed while the driver is loaded; refusing to remove the GPU"
    fi
    if [ -n "$procs" ]; then
        printf 'CUDA processes are still running:\n%s\n' "$procs" >&2
        die "stop them first, then re-run the installer"
    fi

    step "Unloading running nvidia modules"
    for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
        if lsmod | awk '{print $1}' | grep -qx "$m"; then
            modprobe -r "$m" || die "could not unload $m; refusing to remove the GPU"
        fi
    done
fi

step "Writing $CONFIG"
{
    printf '# Written by nvidia-compute-toggle install.sh\n'
    printf 'DGPU_PCI=%q\n' "$GPU_PCI"
    printf 'DGPU_BRIDGE=%q\n' "$GPU_BRIDGE"
    printf 'DGPU_NAME=%q\n' "$GPU_NAME"
} >"$CONFIG"
chmod 0644 "$CONFIG"
info "done"

step "Writing $MODPROBE"
install -m 0644 "$REPO_DIR/files/90-nvidia-compute-off.conf" "$MODPROBE"
info "done"

step "Adding kernel arguments for nouveau/nova_core"
info "$KARGS"
grubby --update-kernel=ALL --args="$KARGS"
if [ -f "$KERNEL_CMDLINE" ]; then
    if ! grep -q 'rd.driver.blacklist=nouveau' "$KERNEL_CMDLINE" ||
       ! grep -q 'modprobe.blacklist=nouveau' "$KERNEL_CMDLINE"; then
        cp -a "$KERNEL_CMDLINE" "${KERNEL_CMDLINE}.bak"
        printf '%s %s\n' \
            "$(sed -e 's/[[:space:]]*$//' "$KERNEL_CMDLINE")" "$KARGS" \
            >"$KERNEL_CMDLINE"
        info "updated $KERNEL_CMDLINE (backup: ${KERNEL_CMDLINE}.bak)"
    else
        info "$KERNEL_CMDLINE already has the arguments"
    fi
else
    info "no $KERNEL_CMDLINE; skipping future-kernel update"
fi

step "Installing $UNIT"
sed "s|@DGPU_PCI@|$GPU_PCI|g" \
    "$REPO_DIR/files/nvidia-compute-off.service.in" >"$UNIT"
chmod 0644 "$UNIT"

if command -v systemd-analyze >/dev/null 2>&1; then
    if ! systemd-analyze verify "$UNIT"; then
        rollback_new_unit
        die "nvidia-compute-off.service failed verification; old unit left untouched"
    fi
fi

systemctl daemon-reload
systemctl enable nvidia-compute-off.service >/dev/null
info "enabled"

step "Masking NVIDIA helper services"
for unit in nvidia-fallback.service nvidia-persistenced.service nvidia-powerd.service; do
    systemctl mask --now "$unit" 2>/dev/null || true
done
info "nvidia-fallback, nvidia-persistenced, nvidia-powerd masked if present"

step "Checking unit ordering"
systemctl show nvidia-compute-off.service -p After -p Before -p WantedBy
if systemctl show nvidia-compute-off.service -p After | grep -q 'multi-user.target'; then
    rollback_new_unit
    die "nvidia-compute-off.service still has After=multi-user.target"
fi
if ! systemctl show nvidia-compute-off.service -p After | grep -q 'akmods.service'; then
    rollback_new_unit
    die "nvidia-compute-off.service is not ordered after akmods.service"
fi
if ! systemctl show nvidia-compute-off.service -p Before |
    grep -Eq 'gdm.service|display-manager.service'; then
    warn "the unit is not ordered before the display manager; check display-manager.service"
fi

# Only remove the old unit after the new one is installed and verified.  If
# anything above failed, the old unit is still present and the next boot is
# unchanged.
if [ -e /etc/systemd/system/disable-nvidia.service ]; then
    step "Migrating old disable-nvidia.service"
    systemctl disable --now disable-nvidia.service 2>/dev/null || true
    rm -f /etc/systemd/system/disable-nvidia.service
    rm -rf /etc/systemd/system/disable-nvidia.service.d
    systemctl daemon-reload
    info "removed the old unit and its drop-in"
fi

step "Installing the CLI and docs"
install -Dm0755 "$REPO_DIR/bin/nvidia-compute" "$BINDIR/nvidia-compute"
install -d "$DATADIR" "$DOCDIR"
install -m0644 "$REPO_DIR/shell/aliases.sh" "$DATADIR/aliases.sh"
install -m0644 "$REPO_DIR/README.md" "$DOCDIR/README.md"
install -m0644 "$REPO_DIR/docs/"*.md "$DOCDIR/"
info "$BINDIR/nvidia-compute"
info "$DOCDIR"

if [ "$WITH_EXTENSION" -eq 1 ]; then
    step "Installing the passwordless helper"
    install -Dm0755 "$REPO_DIR/helper/nvidia-compute-helper" "$HELPER"
    info "$HELPER"

    step "Installing the sudoers rule"
    sudoers_tmp=$(mktemp)
    sed "s|/usr/local/libexec/nvidia-compute-helper|$HELPER|g" \
        "$REPO_DIR/files/nvidia-compute-toggle.sudoers" >"$sudoers_tmp"
    if ! visudo -cf "$sudoers_tmp" >/dev/null; then
        rm -f "$sudoers_tmp"
        die "generated sudoers rule is invalid; helper installed but sudo rule not changed"
    fi
    install -Dm0440 "$sudoers_tmp" "$SUDOERS"
    rm -f "$sudoers_tmp"
    info "$SUDOERS"

    step "Installing the GNOME Quick Settings extension"
    target_user="${SUDO_USER:-}"
    if [ -z "$target_user" ] || [ "$target_user" = "root" ]; then
        warn "could not identify the desktop user (SUDO_USER); extension not copied"
        warn "run the installer with sudo from your desktop session"
    else
        target_home=$(getent passwd "$target_user" | cut -d: -f6)
        target_uid=$(id -u "$target_user")
        target_gid=$(id -g "$target_user")
        if [ -z "$target_home" ] || [ "$target_home" = "/" ]; then
            warn "could not resolve home directory for $target_user; extension not copied"
        else
            ext_parent="$target_home/.local/share/gnome-shell/extensions"
            install -d -m0755 -o "$target_user" -g "$target_gid" "$ext_parent"
            rm -rf "${ext_parent:?}/${EXT_UUID:?}"
            cp -a "$REPO_DIR/gnome-extension" "$ext_parent/$EXT_UUID"
            chown -R "$target_user:$target_gid" "$ext_parent/$EXT_UUID"
            chmod -R u=rwX,go=rX "$ext_parent/$EXT_UUID"
            info "$ext_parent/$EXT_UUID"

            if id -nG "$target_user" | tr ' ' '\n' | grep -qx wheel; then
                info "user $target_user is in wheel"
            else
                warn "user $target_user is not in wheel; the sudoers rule will not apply"
            fi

            if command -v gnome-extensions >/dev/null 2>&1 &&
               [ -d "/run/user/$target_uid" ]; then
                if sudo -u "$target_user" \
                    env XDG_RUNTIME_DIR="/run/user/$target_uid" \
                        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$target_uid/bus" \
                        gnome-extensions enable "$EXT_UUID" 2>/dev/null; then
                    info "extension enabled"
                else
                    warn "could not enable the extension now"
                    warn "log out/in, then run: gnome-extensions enable $EXT_UUID"
                fi
            else
                warn "log out/in, then run: gnome-extensions enable $EXT_UUID"
            fi
        fi
    fi
fi

if [ "$START_NOW" -eq 1 ]; then
    step "Removing the dGPU now"
    if [ -e "/sys/bus/pci/devices/$GPU_PCI" ]; then
        if systemctl is-active --quiet nvidia-compute-off.service; then
            # Re-run a unit that is already active from an earlier boot/install.
            systemctl restart nvidia-compute-off.service
        else
            systemctl start nvidia-compute-off.service
        fi
    fi
    if [ -e "/sys/bus/pci/devices/$GPU_PCI" ]; then
        die "GPU is still present after starting nvidia-compute-off.service"
    fi
    state=""
    for _ in {1..50}; do
        state=$(cat "/sys/bus/pci/devices/$GPU_BRIDGE/power_state" 2>/dev/null || true)
        [ "$state" = "D3cold" ] && break
        sleep 0.1
    done
    [ "$state" = "D3cold" ] ||
        die "bridge $GPU_BRIDGE is ${state:-unknown}, expected D3cold"
    info "GPU removed; bridge $GPU_BRIDGE is D3cold"
else
    info "--no-start: the GPU will be removed on the next boot"
fi

step "Done"
cat <<EOF
Installed nvidia-compute-toggle.

Config:  $CONFIG
Unit:    $UNIT
CLI:     $BINDIR/nvidia-compute
Docs:    $DOCDIR/README.md

Next:
  nvidia-compute status
  nvidia-compute state
  nvidia-compute on
  nvidia-compute off
  nvidia-compute doctor

If you previously used cuda-on/cuda-off shell functions from another setup,
remove them or source the new wrappers:

  source $DATADIR/aliases.sh
EOF

if [ "$WITH_EXTENSION" -eq 1 ]; then
    cat <<'EOF'

GNOME Quick Settings:
  If the CUDA tile is not visible, log out and back in.  Then check:

    gnome-extensions info nvidia-compute-toggle@lukas

  The helper is installed at:
    /usr/local/libexec/nvidia-compute-helper

  The sudoers rule is:
    /etc/sudoers.d/nvidia-compute-toggle
EOF
fi
