# nvidia-compute-toggle

On-demand CUDA for muxless NVIDIA Optimus laptops on Fedora.

The iGPU owns the display. The dGPU is removed from the PCI bus by default so it
draws no power, then brought back only when you need CUDA:

```bash
nvidia-compute status
nvidia-compute on
nvidia-compute off
```

This is not Optimus/PRIME graphics offload. There is no `DRI_PRIME`, no
`__NV_PRIME_RENDER_OFFLOAD`, no `nvidia_drm`, no `nvidia_modeset`, and no NVIDIA
Xorg driver. The dGPU is a compute device only.

The project also includes an optional **GNOME Quick Settings** tile, so you can
toggle CUDA from the top-right menu like dark mode. See
[`docs/gnome-quick-settings.md`](docs/gnome-quick-settings.md).

## Status

Tested on:

- Dell XPS 15 9570
- Intel UHD 630 iGPU, NVIDIA GP107M GTX 1050 Mobile (`10de:1c8d`)
- Fedora 44
- RPMFusion NVIDIA 580.178.04 (proprietary, last Pascal branch)
- Kernel 7.2.11 and 6.19.10

The first version targets **Fedora + Pascal/580xx**. Turing and newer may work,
but the open-vs-proprietary module handling is documented rather than
automated.

## Requirements

- A laptop where the iGPU drives all displays and the dGPU has no display
  connectors. If the dGPU owns a panel or a mux, do not use this.
- Fedora with `systemd`, `grubby`, `lspci`, and an RPMFusion NVIDIA driver.
- For Pascal: the **proprietary** 580xx module. `nvidia-open` does not work
  because Pascal has no GSP.
- Secure Boot disabled, or the akmod modules signed and enrolled.
- Root access for install/uninstall and for `on`/`off`.

## Driver setup first

This project does not install the NVIDIA driver. Follow
[`docs/driver-setup.md`](docs/driver-setup.md). Short version for Pascal:

```bash
sudo dnf install \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

sudo dnf install "kernel-devel-$(uname -r)" \
  akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx-cuda

# The GPU must be visible while the akmod is built.
lspci -nn | grep '10de:1c8d'
sudo akmods --rebuild --akmod nvidia-580xx

# Must say NVIDIA, not Dual MIT/GPL
modinfo nvidia | grep -E '^(license|description):'
```

If `license:` says `Dual MIT/GPL`, the open module was built. See
[`docs/driver-setup.md`](docs/driver-setup.md) and
[`docs/troubleshooting.md`](docs/troubleshooting.md).

## Install

```bash
git clone <this-repo> ~/Repos/nvidia-compute-toggle
cd ~/Repos/nvidia-compute-toggle

# Inspect the plan without changing anything
./install.sh --check

# Install and remove the dGPU now
sudo ./install.sh

# Or install but wait until the next boot to remove it
sudo ./install.sh --no-start

# Also install the GNOME Quick Settings tile (passwordless helper)
sudo ./install.sh --with-extension
```

The installer:

- detects the NVIDIA VGA/3D controller and its parent PCI bridge
- writes `/etc/nvidia-compute-toggle.conf`
- blacklists `nouveau`, `nova_core`, `nvidia`, `nvidia_uvm`, `nvidia_drm`,
  and `nvidia_modeset`
- adds `rd.driver.blacklist=nouveau,nova_core` and
  `modprobe.blacklist=nouveau,nova_core` to the kernel command line
- installs `nvidia-compute-off.service`
- masks `nvidia-fallback`, `nvidia-persistenced`, and `nvidia-powerd`
- installs the `nvidia-compute` CLI and docs
- migrates an existing `disable-nvidia.service` from `nvidia-disable`
- with `--with-extension`, installs the root helper, the narrow sudoers rule,
  and the GNOME Quick Settings extension for the invoking desktop user

It does **not** remove the GPU if a CUDA process is running.

The old unit is only removed after the new unit has been verified. If the new
unit fails validation, the old one is left in place.

## Usage

```bash
# Show the current state
nvidia-compute status
nvidia-compute state        # state=on | state=off | state=transition

# Turn the GPU on and verify it
nvidia-compute on
nvidia-smi

# Turn it off again
nvidia-compute off

# Check the installation
nvidia-compute doctor

# Toggle based on current state
nvidia-compute toggle
```

`nvidia-compute on` refuses if:

- `nouveau` or `nova_core` is still loaded
- the built module is `nvidia-open` on Pascal
- the GPU does not appear after a PCI rescan

`nvidia-compute off` refuses if:

- a CUDA compute process is still running
- an NVIDIA module cannot be unloaded
- the parent bridge does not reach `D3cold`

Optional shell wrappers:

```bash
. /usr/share/nvidia-compute-toggle/aliases.sh
```

That defines `cuda-on`, `cuda-off`, `cuda-status`, `cuda-doctor`, and `cuda-run`.
Remove any older `cuda-*` functions from `~/.aliases` first; the last definition
wins.

## GNOME Quick Settings

Install the optional tile with:

```bash
sudo ./install.sh --with-extension
```

It adds a **CUDA** toggle to the top-right Quick Settings menu, with a
passwordless helper limited to `on`, `off`, and `toggle`. If the tile does not
appear immediately on Wayland, log out and back in.

See [`docs/gnome-quick-settings.md`](docs/gnome-quick-settings.md) for the
security tradeoff, debugging, and manual enable/disable commands.

## How it works

At boot:

```text
akmods.service
  └─ builds the NVIDIA module while the dGPU is visible
nvidia-compute-off.service
  ├─ writes "disabled" to <dGPU>/power/wakeup
  ├─ writes 1 to <dGPU>/remove
  └─ parent bridge enters D3cold
gdm.service / Wayland
  └─ iGPU only
```

`nvidia-compute on`:

```text
rescan PCI
  └─ dGPU appears
       └─ modprobe nvidia + nvidia_uvm
            └─ /dev/nvidia0 + /dev/nvidia-uvm
                 └─ nvidia-smi / CUDA
```

`nvidia-compute off` reverses it and waits for `D3cold`.

The unit ordering matters:

- `After=akmods.service` — the akmod build must see the GPU, otherwise
  RPMFusion can build `nvidia-open`, which does not support Pascal.
- `Before=display-manager.service` — the GPU is gone before GDM/Wayland starts.
- `ConditionPathExists=` — if the GPU is already absent, the unit is skipped.

## Kernel updates

`akmods.service` rebuilds the module at boot. The unit ordering keeps the GPU
visible during that build.

After a kernel update:

```bash
uname -r
modinfo nvidia | grep -E '^(version|license):'
nvidia-compute status
nvidia-compute on
nvidia-smi
nvidia-compute off
```

If the module is missing or open:

```bash
sudo dnf install "kernel-devel-$(uname -r)"
lspci -nn | grep '10de:1c8d'      # if absent: echo 1 | sudo tee /sys/bus/pci/rescan
sudo akmods --rebuild --akmod nvidia-580xx
```

`akmods --force` only retries failed builds; it does not rebuild an installed
module.

## Safety and limitations

- Do not suspend/hibernate with CUDA active. Run `nvidia-compute off` first.
- Do not enable Secure Boot without signing/enrolling the akmod modules.
- Pascal is supported by the 580 branch only. Do not install the 595/615
  driver or CUDA 13 wheels.
- The display must remain on the iGPU. If your laptop has a mux or dGPU display
  outputs, this project is not for you.
- A driverless PCI device left present can keep the parent bridge awake. That is
  why the project removes the device rather than only blacklisting drivers.
- The ACPI `PEG0.PEGP.BRT6.LCD` errors seen on some Dell firmware are harmless
  and disappear when the dGPU is removed. See
  [`docs/troubleshooting.md`](docs/troubleshooting.md).
- `--with-extension` installs a passwordless sudoers rule for the exact
  `on`/`off`/`toggle` helper. Any process running as a `wheel` user can toggle
  the GPU. It cannot run arbitrary root commands, but it can change GPU power
  state. Remove `/etc/sudoers.d/nvidia-compute-toggle` to revoke it.

## Uninstall

```bash
sudo ./uninstall.sh
sudo reboot
```

This removes the unit, config, blacklists, kernel arguments, CLI, docs, and the
optional helper/sudoers/extension. It does not remove the NVIDIA driver
packages.

## Files

| Path | Purpose |
|---|---|
| `/etc/nvidia-compute-toggle.conf` | detected GPU and bridge |
| `/etc/systemd/system/nvidia-compute-off.service` | boot-time rail-off unit |
| `/etc/modprobe.d/90-nvidia-compute-off.conf` | module blacklists |
| `/usr/local/bin/nvidia-compute` | CLI |
| `/usr/share/nvidia-compute-toggle/aliases.sh` | optional shell wrappers |
| `/usr/share/doc/nvidia-compute-toggle/` | README, driver notes, troubleshooting |
| `/usr/local/libexec/nvidia-compute-helper` | passwordless root helper (optional) |
| `/etc/sudoers.d/nvidia-compute-toggle` | narrow sudoers rule (optional) |
| `~/.local/share/gnome-shell/extensions/nvidia-compute-toggle@lukas/` | Quick Settings extension (optional) |

## Documentation

- [`docs/driver-setup.md`](docs/driver-setup.md) — RPMFusion, proprietary vs
  open module, PyTorch cu126.
- [`docs/design.md`](docs/design.md) — why remove/rescan, boot flow, constraints.
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — boot hangs, ACPI noise,
  `No such device`, D3cold failures.
- [`docs/migration-from-nvidia-disable.md`](docs/migration-from-nvidia-disable.md)
  — replacing the old unit and `cuda-*` shell functions.
- [`docs/gnome-quick-settings.md`](docs/gnome-quick-settings.md) — Quick Settings
  tile, passwordless helper, security tradeoff, debugging.

## Credits

Inspired by [`donfreiday/nvidia-disable`](https://github.com/donfreiday/nvidia-disable),
which documents the PCI remove/rescan and D3cold technique for permanently
disabling a faulty dGPU on the XPS 15 9570. This is an independent rewrite for
the opposite use case: keeping the dGPU available for on-demand compute.

## License

MIT for this project's original code. See [`LICENSE`](LICENSE) and
[`NOTICE`](NOTICE).

This is an independent implementation, not a git fork of `nvidia-disable`. The
upstream repository has no LICENSE file, so no upstream code is relicensed
here. The technique and the original project are credited in [`NOTICE`](NOTICE)
and the Credits section.
