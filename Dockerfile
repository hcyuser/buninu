# Buninu in a VM.
#
# Stage 1 builds a Linux kernel + initramfs whose entire userspace is this
# repository: Bun as the runtime, bunmsh as the shell, jsgotty as the terminal.
# Stage 2 is a thin QEMU image that boots it.
#
#   docker build -t buninu-vm .
#   docker run --rm -it -p 8080:8080 buninu-vm          # browser terminal
#   docker run --rm -it buninu-vm console               # bunmsh on the serial console
#
# The guest runs on the same architecture as the image (x86_64 or aarch64).

ARG ALPINE_VERSION=3.21

FROM alpine:${ALPINE_VERSION} AS vmbuilder

ARG ALPINE_VERSION=3.21
# "latest", or a Bun version such as 1.2.21
ARG BUN_VERSION=latest

RUN apk add --no-cache curl unzip cpio gzip kmod

# ---------------------------------------------------------------------------
# A minimal Alpine root filesystem, built with apk from the host's own
# repositories. linux-virt brings both the kernel and its modules. This step
# pulls roughly 100 MB from dl-cdn and apk downloads as it installs, so its
# duration is whatever the link gives you: measured runs ranged from 3 seconds
# to 5 minutes. The layer caches, so only the first build pays for it.
# ---------------------------------------------------------------------------
RUN set -eu; \
    mkdir -p /rootfs/etc/apk; \
    cp -a /etc/apk/keys /rootfs/etc/apk/keys; \
    printf '%s\n' \
      "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main" \
      "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" \
      > /rootfs/etc/apk/repositories; \
    apk add --root /rootfs --initdb --no-cache \
      --repositories-file /rootfs/etc/apk/repositories \
      alpine-base \
      linux-virt \
      kmod \
      iproute2 \
      libgcc \
      libstdc++ \
      ca-certificates \
      ncurses-terminfo-base \
      bash \
      curl

# Pull the kernel out of the rootfs, drop module trees a VM never touches,
# then rebuild the dependency index.
RUN set -eu; \
    mkdir -p /out; \
    cp /rootfs/boot/vmlinuz-virt /out/vmlinuz; \
    rm -rf /rootfs/boot; \
    kver=$(ls /rootfs/lib/modules); \
    for dir in drivers/gpu drivers/media drivers/infiniband drivers/net/wireless sound; do \
      rm -rf "/rootfs/lib/modules/$kver/kernel/$dir"; \
    done; \
    depmod -b /rootfs "$kver"

# ---------------------------------------------------------------------------
# Bun. The x86_64 guest may run under TCG emulation without AVX2, so use the
# baseline build there; both are the musl builds, for Alpine.
# ---------------------------------------------------------------------------
RUN set -eu; \
    case "$(apk --print-arch)" in \
      x86_64)  asset=bun-linux-x64-musl-baseline.zip ;; \
      aarch64) asset=bun-linux-aarch64-musl.zip ;; \
      *) echo "unsupported architecture: $(apk --print-arch)" >&2; exit 1 ;; \
    esac; \
    if [ "$BUN_VERSION" = latest ]; then \
      url="https://github.com/oven-sh/bun/releases/latest/download/$asset"; \
    else \
      url="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/$asset"; \
    fi; \
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
      -o /tmp/bun.zip "$url"; \
    unzip -j -o /tmp/bun.zip '*/bun' -d /rootfs/usr/local/bin; \
    chmod 0755 /rootfs/usr/local/bin/bun; \
    rm -f /tmp/bun.zip

# ---------------------------------------------------------------------------
# The userspace itself: this repository, and the init that starts it.
# ---------------------------------------------------------------------------
COPY docker/vm-init.sh /rootfs/init
COPY . /rootfs/opt/buninu

RUN set -eu; \
    chmod 0755 /rootfs/init; \
    rm -rf /rootfs/opt/buninu/.git /rootfs/opt/buninu/Dockerfile /rootfs/opt/buninu/docker; \
    mkdir -p /rootfs/root; \
    cp -f /rootfs/opt/buninu/.bashrc /rootfs/root/.bashrc; \
    printf 'buninu\n' > /rootfs/etc/hostname; \
    printf '127.0.0.1 localhost buninu\n' > /rootfs/etc/hosts; \
    printf 'nameserver 10.0.2.3\n' > /rootfs/etc/resolv.conf; \
    sh /rootfs/opt/buninu/bin/switch_to_linux.sh >/dev/null 2>&1 || true

RUN set -eu; \
    cd /rootfs && find . -print0 \
      | cpio --null --create --format=newc --quiet \
      | gzip -6 > /out/initramfs.gz; \
    ls -lh /out

# ---------------------------------------------------------------------------
# Stage 2: QEMU, the kernel, and the initramfs.
# ---------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION}

RUN set -eu; \
    case "$(apk --print-arch)" in \
      x86_64)  apk add --no-cache qemu-system-x86_64 ;; \
      aarch64) apk add --no-cache qemu-system-aarch64 ;; \
      *) echo "unsupported architecture: $(apk --print-arch)" >&2; exit 1 ;; \
    esac

COPY --from=vmbuilder /out/vmlinuz /out/initramfs.gz /srv/buninu/
COPY docker/entrypoint.sh /usr/local/bin/buninu-vm
RUN chmod 0755 /usr/local/bin/buninu-vm

ENV BUNINU_MODE=web \
    BUNINU_PID1=shell \
    BUNINU_PORT=8080 \
    BUNINU_MEMORY=2048 \
    BUNINU_CPUS=2 \
    BUNINU_SHELL=bunmsh

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/buninu-vm"]
CMD []
