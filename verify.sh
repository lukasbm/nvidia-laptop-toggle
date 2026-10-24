#!/usr/bin/env bash
# Verify the installed "off" state.  No root required.
set -uo pipefail

CONFIG=${NVIDIA_COMPUTE_CONFIG:-/etc/nvidia-compute-toggle.conf}
DGPU_PCI=""
DGPU_BRIDGE=""

rc=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; rc=1; }
note() { printf '  --    %s\n' "$*"; }

readfile() {
    cat "$1" 2>/dev/null || true
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[ -r "$CONFIG" ] || die "missing $CONFIG; is nvidia-compute-toggle installed?"
# shellcheck disable=SC1090
. "$CONFIG"
: "${DGPU_PCI:?DGPU_PCI missing from $CONFIG}"
: "${DGPU_BRIDGE:?DGPU_BRIDGE missing from $CONFIG}"

printf '\nnvidia-compute-toggle verification\n\n'

if [ "$(systemctl is-enabled nvidia-compute-off.service 2>/dev/null || true)" = "enabled" ]; then
    pass "nvidia-compute-off.service is enabled"
else
    fail "nvidia-compute-off.service is not enabled"
fi

after=$(systemctl show nvidia-compute-off.service -p After 2>/dev/null || true)
before=$(systemctl show nvidia-compute-off.service -p Before 2>/dev/null || true)

if printf '%s' "$after" | grep -q 'multi-user.target'; then
    fail "unit has After=multi-user.target (ordering cycle risk)"
else
    pass "unit has no After=multi-user.target"
fi
if printf '%s' "$after" | grep -q 'akmods.service'; then
    pass "unit runs after akmods.service"
else
    fail "unit is not ordered after akmods.service"
fi
if printf '%s' "$before" | grep -Eq 'gdm.service|display-manager.service'; then
    pass "unit runs before the display manager"
else
    note "unit is not explicitly ordered before the display manager"
fi

if [ -e "/sys/bus/pci/devices/$DGPU_PCI" ]; then
    fail "$DGPU_PCI is still present on the PCI bus"
else
    pass "$DGPU_PCI is removed from the bus"
fi

state=""
for _ in {1..50}; do
    state=$(readfile "/sys/bus/pci/devices/$DGPU_BRIDGE/power_state")
    [ "$state" = "D3cold" ] && break
    sleep 0.1
done
if [ "$state" = "D3cold" ]; then
    pass "bridge $DGPU_BRIDGE is D3cold"
else
    fail "bridge $DGPU_BRIDGE is ${state:-unknown}, expected D3cold"
fi

if lsmod | awk '{print $1}' | grep -Eq '^(nouveau|nvidia|nova_core)'; then
    fail "GPU modules are still loaded:"
    lsmod | awk '$1 ~ /^(nouveau|nvidia|nova_core)/ {print "        " $1}' >&2
else
    pass "no nouveau/nvidia/nova_core modules loaded"
fi

for arg in rd.driver.blacklist=nouveau modprobe.blacklist=nouveau; do
    if grep -qw -- "$arg" /proc/cmdline; then
        pass "$arg on the kernel command line"
    else
        fail "$arg missing from /proc/cmdline"
    fi
done

lic=$(modinfo -F license nvidia 2>/dev/null || true)
if [ -z "$lic" ]; then
    fail "no nvidia module for $(uname -r)"
elif [[ "$lic" == *"Dual MIT/GPL"* ]]; then
    fail "nvidia-open is installed; Pascal needs the proprietary module"
else
    pass "nvidia module license: $lic"
fi

for unit in nvidia-fallback.service nvidia-persistenced.service nvidia-powerd.service; do
    if ! systemctl cat "$unit" >/dev/null 2>&1; then
        note "$unit is not installed"
    elif [ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" = "masked" ]; then
        pass "$unit is masked"
    else
        fail "$unit is not masked"
    fi
done

taint=$(readfile /proc/sys/kernel/tainted)
if [ "$taint" = "0" ]; then
    pass "kernel is not tainted"
elif [ -n "$taint" ] && [ $((taint & 512)) -ne 0 ] 2>/dev/null; then
    fail "kernel taint $taint includes a WARNING; check journalctl -b -k"
else
    note "kernel taint is ${taint:-unknown} (not a WARNING)"
fi

printf '\n'
if [ "$rc" -eq 0 ]; then
    printf 'All checks passed.\n\n'
else
    printf 'Some checks failed.\n\n'
fi
exit "$rc"
