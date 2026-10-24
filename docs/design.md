# Design

## Goal

Use a muxless Optimus dGPU as an occasional CUDA device while keeping it
completely off during normal use.

```text
Normal:
  iGPU ───────────────► display
  dGPU ── removed from PCI bus, rail off

CUDA:
  iGPU ───────────────► display
  dGPU ── nvidia + nvidia_uvm ──► /dev/nvidia* ──► CUDA
```

The display never moves to the dGPU. There is no PRIME display offload, no
`DRI_PRIME`, no `nvidia_drm`, and no `nvidia_modeset`.

## Why remove the PCI device?

Pascal does not support NVIDIA's Turing+ runtime D3 power management
(`NVreg_DynamicPowerManagement`). Keeping the proprietary driver loaded keeps
the GPU initialized and powered. Unloading the modules is necessary, but not
always sufficient: a present, driverless PCI device can keep its parent bridge
awake.

The reliable off state is:

1. unload the NVIDIA modules
2. write `1` to `/sys/bus/pci/devices/<dGPU>/remove`
3. wait for the parent bridge to reach `D3cold`

`nvidia-compute on` reverses this with:

```bash
echo 1 > /sys/bus/pci/rescan
```

The kernel re-enumerates the device, then `modprobe nvidia` binds the driver.

## Boot policy

`nvidia-compute-off.service` runs at boot:

```ini
After=akmods.service
Before=display-manager.service
ConditionPathExists=/sys/bus/pci/devices/<dGPU>

[Service]
Type=oneshot
ExecStart=-/bin/sh -c 'echo disabled > .../power/wakeup'
ExecStart=/bin/sh -c 'echo 1 > .../remove'
RemainAfterExit=yes
```

Why the ordering:

- **After `akmods.service`** — RPMFusion's legacy akmod chooses between the
  proprietary and open module at build time by inspecting `lspci`. If the GPU
  is already removed, it can build `nvidia-open`, which does not support Pascal.
- **Before `display-manager.service`** — the GPU is removed before GDM/Wayland
  starts. The display stack never probes it, and the Dell ACPI brightness
  method for the dGPU is not evaluated.
- **ConditionPathExists** — if the GPU is already absent, the unit is skipped.
- **Leading `-`** — a missing `power/wakeup` attribute must not prevent the
  `remove`.
- **RemainAfterExit** — the unit is a one-shot; it should be remembered as
  active after the two writes.

The original `nvidia-disable` unit used `After=multi-user.target` together with
`WantedBy=multi-user.target`. That is an ordering cycle. Adding
`Before=display-manager.service` while keeping the `After=` caused a boot hang
at `plymouth-quit-wait`. This project removes the cycle entirely.

## Module blacklists

`/etc/modprobe.d/90-nvidia-compute-off.conf` blacklists:

```text
nouveau
nova_core
nvidia
nvidia_uvm
nvidia_drm
nvidia_modeset
```

`blacklist` only prevents automatic loading. Explicit `modprobe nvidia` still
works, which is what the CLI uses.

The kernel arguments:

```text
rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core
```

cover the initramfs. A `modprobe.d` file alone is not enough because dracut
bakes a copy into the image at build time, while the kernel arguments are read
at boot from the current command line.

No `dracut --force` is required.

## Driver services

Masked:

- `nvidia-fallback.service` — would `modprobe nouveau` when the NVIDIA module
  is not loaded.
- `nvidia-persistenced.service` — deliberately keeps the GPU initialized.
- `nvidia-powerd.service` — dynamic boost, Turing+.

The NVIDIA suspend/resume/hibernate units remain enabled. Their script exits
immediately when `/proc/driver/nvidia/suspend` is absent, which is the case
while the driver is unloaded. With CUDA active, run `nvidia-compute off` before
suspending.

## CLI behavior

`nvidia-compute on`:

1. Refuses if `nouveau`/`nova_core` is loaded.
2. Refuses if the module is `nvidia-open` (Pascal has no GSP).
3. Rescans the bus if the GPU is absent.
4. Refuses if the device is bound to nouveau.
5. Loads `nvidia` and `nvidia_uvm`.
6. Waits for the driver to bind and for `nvidia_uvm` to be loaded. Device nodes
   can be stale from a previous load, so node existence alone is not trusted.
7. Waits for `/dev/nvidia0` and `/dev/nvidia-uvm`, then verifies with
   `nvidia-smi`.

`nvidia-compute off`:

1. Refuses if a CUDA compute process is running.
2. Unloads `nvidia_uvm`, `nvidia_drm`, `nvidia_modeset`, `nvidia`.
3. Refuses to remove the device if any NVIDIA module remains.
4. Removes the PCI device.
5. Waits for the bridge to reach `D3cold`.

## Constraints

- The iGPU must own all displays. A mux or dGPU display output breaks the model.
- Pascal needs the proprietary 580xx module. `nvidia-open` requires GSP
  (Turing+).
- The 580 branch is the last Pascal branch.
- CUDA 13 dropped Pascal. Use CUDA 12.6 wheels for PyTorch.
- Secure Boot must be off, or the modules must be signed/enrolled.
- You cannot keep the driver loaded and get zero idle power on Pascal.
