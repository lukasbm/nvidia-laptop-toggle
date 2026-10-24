# Troubleshooting

## Quick diagnostics

```bash
nvidia-compute status
nvidia-compute doctor
nvidia-compute on
nvidia-smi
nvidia-compute off
```

Useful checks:

```bash
lspci -nn | grep -E 'VGA|3D'
ls -d /sys/bus/pci/devices/0000:01:00.0
cat /sys/bus/pci/devices/0000:00:01.0/power_state
lsmod | grep -E 'nouveau|nvidia|nova'
modinfo nvidia | grep -E '^(license|description):'
systemctl status nvidia-compute-off.service --no-pager -l
systemctl show nvidia-compute-off.service -p After -p Before -p WantedBy
```

Logs:

```bash
journalctl -b -k | grep -Ei 'nvidia|NVRM|nouveau'
journalctl -b -u nvidia-compute-off.service
journalctl -b -u akmods.service
grep -R -h -E 'Graphics card found|Using nvidia-open|Not using nvidia-open' \
  /var/cache/akmods/nvidia-580xx | tail
```

## `modprobe nvidia: No such device`

This almost always means the **open** module was built.

```bash
modinfo nvidia | grep -E '^(license|description):'
```

If it says `Dual MIT/GPL`:

1. Make the dGPU visible:

   ```bash
   lspci -nn | grep '10de:1c8d'
   # If absent:
   echo 1 | sudo tee /sys/bus/pci/rescan
   ```

2. Rebuild with the GPU visible:

   ```bash
   sudo akmods --rebuild --akmod nvidia-580xx
   ```

3. Verify:

   ```bash
   modinfo nvidia | grep -E '^(license|description):'
   ```

`akmods --force` only retries failed builds. It does not rebuild an installed
module. Use `--rebuild`.

The build log should contain:

```text
Graphics card found with PCI ID: 10de:1c8d
Not using nvidia-open
```

If it says `No matching graphics card found` / `Using nvidia-open`, the GPU was
not visible during the build. Rescan and rebuild.

## `nvidia-compute on` says nouveau/nova_core is loaded

The current boot still has the old module. Reboot. The kernel arguments and
modprobe blacklist apply on the next boot.

If the problem persists:

```bash
cat /proc/cmdline
grep -E 'blacklist.*nouveau' /etc/modprobe.d/*.conf
```

The command line should contain:

```text
rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core
```

## `nvidia-compute off` refuses

Check for CUDA processes:

```bash
nvidia-smi --query-compute-apps=pid,process_name --format=csv
```

Stop Jupyter, Python, training jobs, or anything holding `/dev/nvidia*`. Then
retry.

If `modprobe -r` says the module is in use but no compute process is listed, a
non-compute process may hold the device (an NVML monitor, OpenCL/Vulkan app, or
a stale process). Close it.

## Bridge does not reach D3cold

```bash
nvidia-compute status
ls -d /sys/bus/pci/devices/0000:01:00.0
lsmod | grep nvidia
cat /sys/bus/pci/devices/0000:00:01.0/power_state
```

Common causes:

- an NVIDIA module is still loaded
- the GPU is still present
- a process holds `/dev/nvidia*`
- the unit did not run

If the GPU is absent but the bridge reports `D0`, wait a second and check again.
Reading some PCI attributes can briefly resume the bridge. `nvidia-compute
status` reads only `power_state`/`runtime_status`, which is safe, but other
tools may wake it.

## Boot hangs at `plymouth-quit-wait`

A systemd ordering cycle. The unit must not have both:

```ini
After=multi-user.target
WantedBy=multi-user.target
```

Check:

```bash
systemctl show nvidia-compute-off.service -p After -p Before
```

`After=` must not contain `multi-user.target`, and it should contain
`akmods.service`. `Before=` should contain the display manager.

Recovery:

1. At GRUB, press `e` on the Fedora entry.
2. Append to the `linux` line:

   ```text
   systemd.unit=emergency.target
   ```

3. Boot with `Ctrl-X`.
4. In the emergency shell:

   ```bash
   sudo systemctl disable nvidia-compute-off.service
   sudo reboot
   ```

5. Once booted, reinstall or repair the unit, then re-enable it.

If the emergency flag was added persistently:

```bash
sudo grubby --update-kernel=ALL --remove-args="systemd.unit=emergency.target"
```

`/etc/kernel/cmdline` should not contain it.

## ACPI `PEG0.PEGP.BRT6.LCD` errors

Example:

```text
ACPI BIOS Error (bug): Could not resolve symbol [\_SB.PCI0.PEG0.PEGP.BRT6.LCD], AE_NOT_FOUND
ACPI Error: Aborting method \_SB.PCI0.PEG0.PEGP.BRT6
ACPI Error: Aborting method \EV5
ACPI Error: Aborting method \SMIE
ACPI Error: Aborting method \_SB.PCI0.LPCB.ECDV._Q66
```

What it means:

- `PEG0.PEGP` is the PCIe root port and the dGPU.
- `BRT6` is an ACPI brightness method for a panel attached to the dGPU.
- `.LCD` does not exist because this laptop has no dGPU-attached panel.
- A Dell EC event (`_Q66`) evaluates the method, fails, and ACPI aborts the
  method chain.

This is a **Dell firmware/DSDT bug**, not a kernel or NVIDIA failure. It appears
while the dGPU is present with no driver. When the unit removes the GPU before
GDM, the errors disappear.

It is not the cause of the boot hang. It only matters if brightness hotkeys or
EC events misbehave. The internal panel uses `intel_backlight` on the iGPU.

## Other harmless log noise

- `ACPI BIOS Error ... XHC.RHUB ... AE_ALREADY_EXISTS` — Dell DSDT duplicate USB
  objects. Harmless.
- `i915 ... Failed to probe lspcon` — Intel HDMI LSPCON probe failure,
  pre-existing. Investigate only if HDMI output fails.
- `wlp59s0: failed to remove key ... (-110)` — ath10k firmware warning. Ignore
  if Wi-Fi works.
- `systemd-logind: Existing logind session ID ...` — multiple sessions; cosmetic.
- GNOME Weather / GlobalShortcuts errors — GNOME app bugs; unrelated.

## `nvidia-smi` shows CUDA 13.0

Normal. The 580 driver reports its maximum supported CUDA version. PyTorch
cu126 uses its own 12.6 runtime. Pascal support in the driver is what matters.

## Kernel update broke CUDA

Check:

```bash
uname -r
modinfo nvidia | grep -E '^(version|license):'
nvidia-compute doctor
```

If missing:

```bash
sudo dnf install "kernel-devel-$(uname -r)"
lspci -nn | grep '10de:1c8d'
# If absent:
echo 1 | sudo tee /sys/bus/pci/rescan
sudo akmods --rebuild --akmod nvidia-580xx
```

Then reboot. `nvidia-compute-off.service` is ordered after `akmods.service`, so
the GPU should be visible during the build.

## Secure Boot

If Secure Boot is enabled, unsigned akmod modules will not load. Either disable
Secure Boot or sign the modules and enroll the key with MOK. This project does
not automate that.

## Fingerprint / sudo prompts

`nvidia-compute on` and `off` use `sudo` for the PCI rescan, `modprobe`, and
`remove` writes. With fingerprint authentication, a failed match just means
sudo did not authenticate; retry or use your password.

## Emergency boot and the old `disable-nvidia.service`

If you are migrating from `nvidia-disable`, the installer disables and removes
`/etc/systemd/system/disable-nvidia.service` and its drop-in. If both units
exist, they can fight over the same PCI device. Check:

```bash
systemctl list-unit-files | grep -E 'nvidia|disable'
```

Only `nvidia-compute-off.service` should manage the rail.

## Uninstall

```bash
sudo ./uninstall.sh
sudo reboot
```

If nouveau still does not load after uninstall, the initramfs may still contain
an old blacklist. After checking `/boot` space:

```bash
sudo dracut --force
sudo reboot
```
