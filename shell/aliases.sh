# shellcheck shell=bash
# Optional shell wrappers for nvidia-compute-toggle.
#
# Source this file from ~/.bashrc after the CLI is installed:
#   . /usr/share/nvidia-compute-toggle/aliases.sh
#
# If you previously defined cuda-on/cuda-off/cuda-status in ~/.aliases,
# remove those definitions first; later definitions win.

cuda-on() {
    nvidia-compute on "$@"
}

cuda-off() {
    nvidia-compute off "$@"
}

cuda-status() {
    nvidia-compute status "$@"
}

cuda-doctor() {
    nvidia-compute doctor "$@"
}

cuda-run() {
    nvidia-compute on || return
    "$@"
    local rc=$?
    nvidia-compute off
    return "$rc"
}
