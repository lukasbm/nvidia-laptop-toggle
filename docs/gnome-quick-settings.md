# GNOME Quick Settings extension

The project includes a small GNOME Shell extension that adds a **CUDA** toggle
to the Quick Settings menu, next to Wi-Fi, Bluetooth, dark mode, etc.

It is bundled here rather than depending on a third-party extension.

Tested on GNOME Shell 50.6 / Wayland.

## What it does

- **Off**: GPU removed from the PCI bus, bridge `D3cold`, switch off.
- **On**: driver loaded, `/dev/nvidia*` available, switch on.
- **Busy**: briefly disables the switch while running `on`/`off`.
- **Failure**: reverts the switch and shows a notification. For example, if a
  CUDA process is running, `off` is refused and the switch stays on.
- **Transition**: GPU or module in an intermediate state. Clicking again
  attempts to clean up (prefer off if the GPU/module is present).

The switch represents **GPU power/driver availability**, not whether a CUDA
process is currently running.

## Install

```bash
cd ~/Repos/nvidia-compute-toggle
sudo ./install.sh --with-extension
```

This installs:

- `/usr/local/libexec/nvidia-compute-helper`
- `/etc/sudoers.d/nvidia-compute-toggle`
- `~/.local/share/gnome-shell/extensions/nvidia-compute-toggle@lukas/`

It also tries to enable the extension for the invoking desktop user. On
Wayland, if the tile does not appear:

```bash
gnome-extensions enable nvidia-compute-toggle@lukas
```

or log out and back in.

Check:

```bash
gnome-extensions info nvidia-compute-toggle@lukas
```

## How privilege works

The extension runs inside GNOME Shell as your user. It cannot write PCI sysfs
or run `modprobe`.

The root helper accepts only three actions:

```text
/usr/local/libexec/nvidia-compute-helper on
/usr/local/libexec/nvidia-compute-helper off
/usr/local/libexec/nvidia-compute-helper toggle
```

The sudoers rule allows the `wheel` group to run those exact commands without a
password:

```text
%wheel ALL=(root) NOPASSWD: /usr/local/libexec/nvidia-compute-helper on, ...
```

The helper executes `/usr/local/bin/nvidia-compute` as root. The CLI still
checks for running CUDA processes and refuses unsafe `off` requests.

### Security tradeoff

Any process running as a `wheel` user can toggle the GPU without a password. It
cannot run arbitrary root commands through this rule, but it can power the dGPU
on/off. If that is not acceptable, do not use `--with-extension`; use the CLI
with normal sudo, or build a polkit/D-Bus service with authentication.

Remove `/etc/sudoers.d/nvidia-compute-toggle` to revoke the passwordless path.

## How the tile detects state

The extension reads:

```text
/etc/nvidia-compute-toggle.conf
/sys/bus/pci/devices/<DGPU_PCI>
/sys/module/nvidia
/sys/bus/pci/devices/<DGPU_BRIDGE>/power_state
```

It polls every 3 seconds. No privileged operation is used for status.

## Debugging

Shell logs:

```bash
journalctl --user -f -o cat /usr/bin/gnome-shell
```

or:

```bash
journalctl --user -f | grep -i nvidia-compute
```

Check the extension:

```bash
gnome-extensions info nvidia-compute-toggle@lukas
gnome-extensions list --enabled
```

Test the helper directly:

```bash
sudo -n /usr/local/libexec/nvidia-compute-helper off
echo $?
```

Test state sync:

```bash
nvidia-compute state        # state=on | state=off | state=transition
```

If `sudo -n` says a password is required:

```bash
sudo visudo -cf /etc/sudoers.d/nvidia-compute-toggle
id -nG
```

The user must be in `wheel`.

If the tile says **Not installed**, `/etc/nvidia-compute-toggle.conf` is
missing. Run the installer.

If the tile says **Transition**, the GPU and module disagree (for example the
GPU is present but the driver failed to bind). Clicking prefers cleanup; you
can also run:

```bash
nvidia-compute off
nvidia-compute doctor
```

## Manual enable / disable

```bash
gnome-extensions disable nvidia-compute-toggle@lukas
gnome-extensions enable nvidia-compute-toggle@lukas
```

After editing `extension.js`, on Wayland:

```bash
gnome-extensions disable nvidia-compute-toggle@lukas
gnome-extensions enable nvidia-compute-toggle@lukas
```

If the change does not apply, log out and back in.

## Uninstall

```bash
sudo ./uninstall.sh
```

This disables and removes the extension for the invoking user and removes the
helper and sudoers rule. It does not remove the NVIDIA driver.

## Compatibility

GNOME Shell extension APIs change between releases. The metadata currently
declares GNOME 50 and 51. If a future GNOME release changes Quick Settings, the
extension may need updating; the CLI and boot unit are independent of it.
