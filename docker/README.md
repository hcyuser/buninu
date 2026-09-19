# Buninu in QEMU

A Docker image that boots a Linux kernel under QEMU and hands the whole
userspace to this repository. There is no OpenRC, no getty and no login, and
no supervisor either: the kernel starts [`vm-init.sh`](vm-init.sh), which
mounts the pseudo filesystems, brings up the network, and then `exec`s the
shell — so **`bunmsh` itself is PID 1**. jsgotty, when the browser terminal is
wanted, is started beside it as a separate process, not above it.

This is the `Alpine + Bun + Buninu` stack from
[ARCHITECTURE.md](../ARCHITECTURE.md#native-buninu-linux-distribution), built
as a RAM-only initramfs instead of a disk image.

Buninu is developed in collaboration with the upstream project at
[github.com/jjtseng93/buninu](https://github.com/jjtseng93/buninu), and the
userspace this image boots is that project's source tree.

```text
Docker container
└── QEMU
    └── Linux kernel (Alpine linux-virt)
        ├── PID 1  bun apps/bunmsh/bunmsh          ← on /dev/ttyS0 or /dev/ttyAMA0
        └── PID n  bun bin/init.js --jsgotty …     ← web mode only, a sibling
                   └── bun apps/jsgotty/gotty.js
                       └── bunmsh, one per browser session
```

Seen from inside the running guest:

```text
PID   COMMAND
    1 /usr/local/bin/bun /opt/buninu/bin/../apps/bunmsh/bunmsh
  446 /usr/local/bin/bun /opt/buninu/bin/../apps/jsgotty/gotty.js --reconnect -r -w \
      --webgl -a 0.0.0.0 --port 8080 /opt/buninu/bin/bunmsh
```

PID 1 takes the serial device as its controlling terminal, so job control,
Ctrl-C and window resizing work (`tty` answers `/dev/ttyAMA0`).

## Build

```sh
docker build -t buninu-vm .
```

The guest is built for the image's own architecture: an x86_64 host produces an
x86_64 guest, an arm64 host an aarch64 one. Bun comes from the official musl
build (the baseline variant on x86_64, so it also runs on emulated CPUs
without AVX2). Pin it with `--build-arg BUN_VERSION=1.2.21` if `latest` ever
breaks.

## The browser terminal

```sh
docker run -d --name buninu -p 8080:8080 buninu-vm
```

`-d` is fine here: QEMU does not pass the host's stdin EOF into the guest, so
PID 1 keeps running without a terminal attached. Use `-it` instead when you
also want the console shell.

The URL carries a random path segment, so it has to be read from the log:

```sh
docker logs buninu | grep -A1 listening
```

```text
HTTP server is listening at:
    http://0.0.0.0:8080/8OKed5SNei7dfJuf/
```

Open that path on `localhost` — `http://localhost:8080/8OKed5SNei7dfJuf/` —
and you get bunmsh in the browser, on the same guest, beside the PID 1 shell:

```text
$ echo hello from browser; ps -eo pid,args | head -3
hello from browser
PID   COMMAND
    1 /usr/local/bin/bun /opt/buninu/bin/../apps/bunmsh/bunmsh
    2 [kthreadd]
```

Each browser tab gets its own bunmsh on its own PTY; closing the tab ends that
session and leaves the guest running. jsgotty's own log is at
`/var/log/jsgotty.log` inside the guest.

That random path is the only thing protecting the terminal by default, and
anyone who can reach the port and the path gets a working shell. Set a password
when the port is not purely local:

```sh
docker run -d --name buninu -p 8080:8080 -e BUNINU_CREDENTIAL=user:pass buninu-vm
```

### Why jsgotty is started through `--jsgotty`

`vm-init.sh` launches it as `bun bin/init.js --jsgotty ... /opt/buninu/bin/bunmsh`
rather than the ordinary `bin/init.js --shell bunmsh` flow, because that flow
wraps `buninu.command` in a snippet that ends `fi; exec "$0"` and bunmsh cannot
parse a command after `fi;`:

```sh
bunmsh -c 'if [ 1 -ne 0 ]; then echo a; fi'            # a
bunmsh -c 'if [ 1 -ne 0 ]; then echo a; fi; echo b'    # syntax error: unterminated if
```

Through the ordinary flow the browser session dies the moment it opens
("Connection Closed"). This is a bunmsh parser limitation, not a VM one — it
affects `buninu --shell bunmsh` on any platform — so once bunmsh parses that
construct, `start_jsgotty` can go back to the plain flow. The trade-off today
is that `buninu.command`'s welcome message does not run in the browser session.

## The console

Both modes put `bunmsh` on the container's own terminal as PID 1; `console` is
the same guest without jsgotty:

```sh
docker run --rm -it buninu-vm console
```

## Stopping the guest

`poweroff -f` inside the shell is the graceful way out: the guest powers down,
QEMU exits, the container stops.

Leaving the shell (`exit`, Ctrl-D) is *not* graceful, and that is inherent to
the design you asked for: PID 1 exiting is a kernel panic. The command line
carries `panic=3`, so the kernel resets three seconds later and QEMU, started
with `-no-reboot`, exits — the container still stops, just with a panic message
on the way out.

`Ctrl-a x` quits QEMU from outside the guest.

## What PID 1 = bunmsh costs

Two things a normal init would do, nobody does here:

- **Orphans are not reaped.** Any process whose parent dies becomes a child of
  PID 1, and bunmsh does not `wait()` for them, so they stay as zombies. This
  is why the startup URL is printed synchronously rather than by a background
  helper.
- **No clean shutdown path.** Nothing flushes or stops services on the way
  down; `poweroff -f` resets the machine immediately.

If either matters, `BUNINU_PID1=init` keeps `vm-init.sh` as PID 1 instead: it
runs the shell as a child under `setsid -c`, reaps orphans, and powers the
guest off cleanly when the shell exits.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `BUNINU_MODE` | `web` | `web` also starts jsgotty beside the shell, `console` is the shell alone |
| `BUNINU_PID1` | `shell` | `shell` makes bunmsh PID 1; `init` keeps a supervisor above it |
| `BUNINU_PORT` | `8080` | Guest port, forwarded to the same port on the container |
| `BUNINU_SHELL` | `bunmsh` | Shell the session starts; `bash` or `sh` also work |
| `BUNINU_CREDENTIAL` | *(unset)* | `user:pass` for the browser terminal |
| `BUNINU_MEMORY` | `2048` | Guest RAM in MiB — the whole userspace lives in it |
| `BUNINU_CPUS` | `2` | Guest vCPUs |
| `BUNINU_QEMU_EXTRA` | *(unset)* | Extra QEMU arguments |

Arguments after the mode are passed to QEMU as well:

```sh
docker run --rm -it -p 8080:8080 buninu-vm web -m 4096
```

## Speed

Measured on an M-series Mac under Docker Desktop, which exposes no `/dev/kvm`
and therefore runs the guest under TCG emulation: container start to
`HTTP server is listening` takes about 8.5 seconds. With `/dev/kvm` available
(Linux host, `--device /dev/kvm`) it is faster still. The entrypoint prints
which accelerator it picked.

The build itself takes a few minutes, most of it downloading Bun and
compressing the ~66 MiB initramfs.

## Notes

- The root filesystem is the initramfs, so it lives entirely in guest RAM and
  nothing written inside the VM survives a restart. Mount a host directory into
  the *container* and pass it on with `BUNINU_QEMU_EXTRA` if you need
  persistence.
- Networking is QEMU user-mode (`10.0.2.15/24`, gateway `10.0.2.2`, DNS
  `10.0.2.3`), which gives the guest outbound access without any host
  privileges. `vm-init.sh` tries DHCP first and falls back to those addresses.
- `BUNINU_CREDENTIAL` reaches the guest on the kernel command line, so it is
  readable from `/proc/cmdline` inside the VM.
