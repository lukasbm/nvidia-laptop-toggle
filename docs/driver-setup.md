# Driver setup (Fedora, Pascal / 580xx)

`nvidia-compute-toggle` manages the power state. It does not install the
NVIDIA driver, CUDA, or PyTorch.

This guide targets the tested configuration: Fedora + Pascal + RPMFusion
580xx. Turing and newer can use the same toggle, but the driver branch and
open-module rules differ.

## 1. Enable RPMFusion

The filtered `rpmfusion-nonfree-nvidia-driver` repository only carries the
current driver. The 580xx legacy packages are in the full nonfree repository.

```bash
sudo dnf install \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
```

## 2. Install the 580xx driver and CUDA userspace

```bash
sudo dnf install "kernel-devel-$(uname -r)" \
  akmod-nvidia-580xx \
  xorg-x11-drv-nvidia-580xx-cuda
```

`-cuda` provides `nvidia-smi`, `libcuda.so.1`, and the CUDA userspace
libraries. The full CUDA toolkit (`nvcc`) is not needed for prebuilt PyTorch
wheels.

Do **not** install `akmod-nvidia`, `akmod-nvidia-open`, or the 595/615 driver
packages. The 580 branch is the last one supporting Pascal.

## 3. Make sure the dGPU is visible

RPMFusion's legacy akmod decides at build time whether to build the proprietary
or open module by inspecting `lspci`. The GPU must be on the bus.

```bash
lspci -nn | grep '10de:1c8d'
```

If it is absent because `nvidia-compute-off.service` already removed it:

```bash
echo 1 | sudo tee /sys/bus/pci/rescan
```

Then verify it appears again.

## 4. Build the module locally

If dnf installed a prebuilt `kmod-nvidia-580xx` and it is the open variant,
rebuild locally with the GPU visible:

```bash
sudo akmods --rebuild --akmod nvidia-580xx
```

`akmods --force` only retries failed builds. It does not rebuild an installed
successful kmod.

Check the result:

```bash
modinfo nvidia | grep -E '^(filename|version|license|description):'
```

Correct for Pascal:

```text
license: NVIDIA
description: NVIDIA GPU driver
```

Wrong:

```text
license: Dual MIT/GPL
description: NVIDIA core GPU kernel module
```

`Dual MIT/GPL` is `nvidia-open`, which needs GSP (Turing+). On Pascal it fails:

```text
NVRM: The NVIDIA GPU ... is not supported by open nvidia.ko
NVRM: because it does not include the required GPU System Processor (GSP).
NVRM: None of the NVIDIA devices were initialized.
modprobe: ERROR: could not insert 'nvidia': No such device
```

If that happens, make sure the GPU is visible and rebuild again. Check the
detection line in the build log:

```bash
grep -R -h -E 'Graphics card found|Using nvidia-open|Not using nvidia-open' \
  /var/cache/akmods/nvidia-580xx | tail
```

It should say:

```text
Graphics card found with PCI ID: 10de:1c8d
Not using nvidia-open
```

The helper packages `nvidia-modprobe` and `nvidia-persistenced` may be 615.x
even though the driver is 580.178.04. They are utility packages; the kernel
module and CUDA libraries are still 580.178.04. The toggle masks
`nvidia-persistenced.service`.

## 5. Install the toggle

```bash
cd ~/Repos/nvidia-compute-toggle
./install.sh --check
sudo ./install.sh
```

The installer masks the services that would load nouveau or keep the GPU
awake. It does not remove the driver.

## 6. PyTorch

CUDA 13 dropped Pascal. Use the **cu126** wheels:

```bash
python3 -m venv ~/venvs/torch-cu126
source ~/venvs/torch-cu126/bin/activate
pip install --upgrade pip
pip install --index-url https://download.pytorch.org/whl/cu126 torch
```

Test:

```bash
nvidia-compute on
python - <<'PY'
import torch

print("torch:", torch.__version__)
print("cuda runtime:", torch.version.cuda)
print("available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("gpu:", torch.cuda.get_device_name(0))
    print("capability:", torch.cuda.get_device_capability(0))
    x = torch.randn(4096, 4096, device="cuda")
    y = x @ x
    torch.cuda.synchronize()
    print("matmul mean:", float(y.mean()))
PY
nvidia-compute off
```

Expected:

- `torch.version.cuda` is `12.6`
- `torch.cuda.is_available()` is `True`
- capability is `(6, 1)`

`nvidia-smi` may report a newer maximum CUDA version (for example 13.0). That
is the driver's maximum, not the PyTorch runtime.

## 7. Kernel updates

`akmods.service` rebuilds the module at boot. `nvidia-compute-off.service` is
ordered after it, so the GPU is still visible during the build.

After a kernel update:

```bash
uname -r
modinfo nvidia | grep -E '^(version|license):'
nvidia-compute doctor
nvidia-compute on
nvidia-smi
nvidia-compute off
```

If the module is missing:

```bash
sudo dnf install "kernel-devel-$(uname -r)"
lspci -nn | grep '10de:1c8d'
# If absent:
echo 1 | sudo tee /sys/bus/pci/rescan
sudo akmods --rebuild --akmod nvidia-580xx
```

Reboot after a kernel update.

## 8. Secure Boot

The tested setup has Secure Boot disabled. If you enable it, the akmod modules
must be signed and the key enrolled with MOK. Do not enable Secure Boot and
expect the unsigned modules to load.

## 9. Fedora upgrades

The 580 branch is the last Pascal branch. A future Fedora release may drop the
580xx packages. Options then:

- stay on a release that still has 580xx,
- delay the upgrade,
- use another distribution or a container that provides 580xx,
- or accept CPU-only PyTorch.

Do not “upgrade” to the 595/615 driver expecting Pascal support.
