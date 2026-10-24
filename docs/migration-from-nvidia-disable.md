# Migrating from `nvidia-disable` / old `cuda-*` aliases

If you already used the original `nvidia-disable` repository plus hand-written
`cuda-on` / `cuda-off` functions, the new project replaces both.

## What the installer handles

`install.sh` detects `/etc/systemd/system/disable-nvidia.service` and:

1. installs and verifies `nvidia-compute-off.service` first
2. disables and stops the old unit
3. removes the old unit and any drop-in
4. starts the new unit if the GPU is present

If the new unit fails verification, the old unit is left untouched.

It also writes the new config, modprobe blacklist, kernel arguments, CLI, and
masks. You do not need to run `uninstall.sh` from `nvidia-disable` first.

## What you must clean up manually

The installer does **not** edit your shell files. Remove the old functions from
`~/.aliases` (or wherever they live):

```bash
cuda-on()
cuda-off()
cuda-status()
```

Then use either the CLI directly:

```bash
nvidia-compute on
nvidia-compute off
nvidia-compute status
```

or source the new wrappers:

```bash
. /usr/share/nvidia-compute-toggle/aliases.sh
```

The last definition wins, so if both old and new functions are loaded, whichever
is sourced last is used. Remove the old ones to avoid confusion.

## What stays

- The NVIDIA driver packages.
- The proprietary 580xx kernel module.
- The `nvidia` / `nvidia_uvm` module names.
- Your PyTorch venv.

The new project only replaces the power-toggle plumbing.

## Checklist

```bash
# 1. Install the new project (add --with-extension for the Quick Settings tile)
cd ~/Repos/nvidia-compute-toggle
./install.sh --check
sudo ./install.sh --with-extension

# 2. Remove the old cuda-* functions from ~/.aliases
#    (or replace them with the source line above)

# 3. Verify only the new unit manages the rail
systemctl list-unit-files | grep -Ei 'nvidia|disable'

# 4. Verify the off state
nvidia-compute status
./verify.sh

# 5. Test the toggle
nvidia-compute on
nvidia-smi
nvidia-compute off
```

If the old `disable-nvidia.service` is still present, remove it manually:

```bash
sudo systemctl disable --now disable-nvidia.service
sudo rm -f /etc/systemd/system/disable-nvidia.service
sudo rm -rf /etc/systemd/system/disable-nvidia.service.d
sudo systemctl daemon-reload
```

Do not run both units. They would both write to the same PCI `remove` node.
