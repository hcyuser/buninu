#!/bin/sh
# Boots the Buninu guest under QEMU.
#
#   buninu-vm [web|console] [extra qemu args...]
#
# Everything else comes from the environment:
#   BUNINU_MODE=web|console     both give bunmsh as PID 1 on the container's
#                               terminal (needs -it); web also starts jsgotty
#                               beside it as a separate process
#   BUNINU_PID1=shell|init      shell (default) makes bunmsh itself PID 1;
#                               init keeps a supervisor that powers the guest
#                               off when the shell exits
#   BUNINU_PORT=8080            guest port, forwarded to the same container port
#   BUNINU_SHELL=bunmsh         shell the session starts
#   BUNINU_CREDENTIAL=user:pass password for the browser terminal
#   BUNINU_MEMORY=2048          guest RAM in MiB
#   BUNINU_CPUS=2               guest vCPUs
#   BUNINU_QEMU_EXTRA=...       extra QEMU arguments

set -eu

VM_DIR=/srv/buninu
KERNEL=$VM_DIR/vmlinuz
INITRD=$VM_DIR/initramfs.gz

MODE=${BUNINU_MODE:-web}
PID1=${BUNINU_PID1:-shell}
PORT=${BUNINU_PORT:-8080}
SHELL_NAME=${BUNINU_SHELL:-bunmsh}
CREDENTIAL=${BUNINU_CREDENTIAL:-}
MEMORY=${BUNINU_MEMORY:-2048}
CPUS=${BUNINU_CPUS:-2}

case "${1:-}" in
  web|console) MODE=$1; shift ;;
  -h|--help)
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

arch=$(uname -m)
case "$arch" in
  x86_64)
    qemu=qemu-system-x86_64
    machine="q35"
    console_dev=ttyS0
    net_device=virtio-net-pci
    rng_device=virtio-rng-pci
    ;;
  aarch64)
    qemu=qemu-system-aarch64
    machine="virt"
    console_dev=ttyAMA0
    net_device=virtio-net-device
    rng_device=virtio-rng-device
    ;;
  *)
    echo "buninu-vm: unsupported architecture: $arch" >&2
    exit 1 ;;
esac

# KVM when the container can reach it, plain emulation otherwise. Docker
# Desktop on macOS and Windows has no /dev/kvm, so the guest runs under TCG.
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  accel="-accel kvm -cpu host"
  echo "[buninu-vm] KVM available: the guest runs accelerated"
else
  accel="-accel tcg -cpu max"
  echo "[buninu-vm] no /dev/kvm: the guest runs under emulation (slower boot)"
fi

# panic=3: with the shell as PID 1, leaving it kills init. The kernel then
# resets after three seconds and QEMU, started with -no-reboot, exits.
cmdline="console=${console_dev} panic=3 loglevel=4 buninu.mode=${MODE} buninu.port=${PORT} buninu.shell=${SHELL_NAME} buninu.pid1=${PID1}"
if [ -n "$CREDENTIAL" ]; then
  cmdline="$cmdline buninu.credential.b64=$(printf '%s' "$CREDENTIAL" | base64 | tr -d '\n')"
fi

if [ "$MODE" = web ]; then
  echo "[buninu-vm] browser terminal on port ${PORT}; the URL, which carries a random path, is printed once jsgotty is up"
  if [ -z "$CREDENTIAL" ]; then
    echo "[buninu-vm] no BUNINU_CREDENTIAL set: anything that can reach this port and path gets a shell"
  fi
fi
if [ "$PID1" = shell ]; then
  echo "[buninu-vm] ${SHELL_NAME} runs as PID 1: type 'poweroff -f' to stop the guest; leaving the shell panics the kernel by design"
fi
echo "[buninu-vm] run with -it for the console, and leave QEMU with Ctrl-a x"

# shellcheck disable=SC2086
exec "$qemu" \
  -machine "$machine" \
  $accel \
  -smp "$CPUS" \
  -m "$MEMORY" \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -append "$cmdline" \
  -netdev "user,id=net0,hostfwd=tcp::${PORT}-:${PORT}" \
  -device "$net_device,netdev=net0" \
  -device "$rng_device" \
  -nographic \
  -no-reboot \
  ${BUNINU_QEMU_EXTRA:-} \
  "$@"
