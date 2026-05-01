# GL.iNet GL-X3000 (Spitz AX) — vanilla OpenWrt build

A working OpenWrt 25.12 image for the GL.iNet GL-X3000 (Spitz AX),
including the kernel and userspace pieces needed to drive the
Quectel RM520N-GL 5G modem on the mainline `mhi_pci_generic` +
`mhi_wwan_mbim` path with no proprietary out-of-tree bits, with
ModemManager owning the data plane.

## Why this fork exists

The GL.iNet stock firmware ships an old OpenWrt 21.02 + kernel 5.4
+ a vendor-patched `pcie_mhi` driver that's never been upstreamed.
Vanilla OpenWrt 25.12 (kernel 6.12) supports the rest of the device
out of the box but needs four small fixes before the modem actually
comes up, stays up under load, and lets us keep using our own AT
helpers alongside ModemManager:

1. **`mhi_pci_generic` doesn't recognise the RM520N-GL's PCI ID.**
   Quectel's silicon variant in this device reports the Qualcomm
   vendor ID + a Qualcomm subvendor ID (0x17cb / 0x0308 / 0x17cb /
   0x5201) instead of Quectel's own. Mainline `mhi_pci_generic`
   doesn't list that combination, so the modem never enumerates as
   an MHI device. We carry a 12-line kernel patch under
   `target/linux/generic/pending-6.12/gl-x3000-quectel-pci-id.patch`
   that adds it.

2. **PCIe runtime PM races with MHI's startup ramp.** When the root
   port is allowed to take the modem into D3hot during early MHI
   bring-up, the doorbell write that follows arrives mid-link-retrain,
   the modem firmware sees a malformed TLP and resets, and the host
   gets stuck spinning on `[14] CmpltTO` AER interrupts. Only a host
   reboot recovers — runtime sysfs toggles like `power/control=on`
   reach the device too late. We pin `pcie_port_pm=off` in the
   chosen bootargs (`target/linux/mediatek/dts/mt7981a-glinet-gl-x3000-xe3000-common.dtsi`)
   so the kernel never tries to take the link down.

3. **ModemManager has no port blacklist without udev.** OpenWrt's
   ModemManager package is built with `-Dudev=false` and gets its
   port discovery via `/etc/hotplug.d/{tty,net,wwan}/25-modemmanager-*`
   shell scripts that call `mmcli --report-kernel-event`. There's no
   equivalent of udev's `ID_MM_DEVICE_IGNORE` blacklist in this
   build, so MM grabs every tty it sees — including the RM520N's
   USB-side `/dev/ttyUSB[0-3]` (DIAG/NMEA/AT/AT2), which our
   `quectel-5g-tools` helpers (`5g-info`, `5g-monitor`, `5g-lock`,
   `5g-led-bars`) need to talk raw AT to. We patch the tty hotplug
   script via `x3000/patches/0001-modemmanager-tty-honour-ignore-tty.patch`
   to honour an `/etc/modemmanager/ignore-tty` allow-list (shipped
   by `quectel-5g-tools`) so MM keeps managing only the MHI control
   surface (`/dev/wwan0at0`, `/dev/wwan0mbim0`).

4. **curl autodetects the brotli we keep around for android-tools.**
   `android-tools` pulls libbrotli into staging, OpenWrt's curl
   Makefile has no DEPENDS line for it, and curl's configure happily
   links libcurl against `libbrotlidec.so.1` if it sees the headers
   — which trips the install-time `.so` sanity check with
   _"Package libcurl is missing dependencies"_. Patched via
   `x3000/patches/0002-curl-disable-brotli-autodetect.patch` to pass
   `--without-brotli` explicitly.

## What's different from a stock OpenWrt 25.12 build

Commits on top of upstream `openwrt-25.12`:

  * `mhi_pci_generic: claim Quectel RM520N-GL with Qualcomm subvendor IDs`
  * `mediatek: glinet gl-x3000: disable PCIe runtime PM via pcie_port_pm=off`
  * `x3000: persistent build configuration for the bad.ass fleet`
  * `swap modem stack from umbim+watchdog to ModemManager`
  * `patch curl to disable brotli autodetect`

Plus the build-prep machinery under `x3000/` (incl. patches to feed
files applied at the end of `prepare.sh`).

The build config drops a few things that upstream's GL-X3000 device
recipe pulls in:

  * **samba4-server + luci-app-samba4.** The fleet doesn't share
    files over SMB.
  * **kmod-scsi-core + kmod-usb-storage.** No USB storage use case.

And adds:

  * **ModemManager + libmm-glib + dbus + luci-proto-modemmanager.**
    MM owns the data plane: connect/reconnect, PIN unlock, signal
    monitoring, RAT change handling, carrier-side disconnect
    recovery. Replaces a previous DIY approach (umbim + a custom
    `mbim-watchdog`) that couldn't reliably catch silent idle-timer
    drops on this firmware.
  * **adb + fastboot** (nmeum/android-tools 35.0.2 with a small patch
    fixing the libusb claim bug for non-contiguous USB interface
    numbers — the RM520N publishes interfaces 0,1,2,3,5 and the
    upstream client iterates by array index).
  * **qfirehose** (vjt fork pinned at 1.4.17; upstream 1.4.11 bricks
    RM520N).
  * **quectel-5g-tools** (Lua AT helpers `5g-info`, `5g-monitor`,
    `5g-lock`, `modem-debug` reading `/dev/ttyUSB2`; the `5g-led-bars`
    procd daemon driving the panel signal LEDs from PCC/SCC NR-RSRP;
    a Prometheus collector; the `/etc/modemmanager/ignore-tty`
    config telling our patched MM hotplug script which tty ports
    to leave alone).
  * **pciutils + usbutils** (lspci / lsusb baked in for diagnosing
    modem PCIe / USB topology).
  * **libmbim + mbim-utils**: pulled in by ModemManager and kept
    available for diagnostics (`mbimcli`, `mbim-proxy`).
  * **speedtest-go**, **wifi-dethrash-collector**.
  * **telegraf-full** — *private variant only*, since it pushes
    metrics to `metrics.bad.ass` which only exists inside the home
    network. Toggled in `x3000/config.private`.
  * **procps-ng-ps**: real `ps` replacing busybox's stub, swapped in
    via the OpenWrt alternatives system at `/bin/ps`.

## Hardware

| Field | Value |
|---|---|
| Device | GL.iNet GL-X3000 (Spitz AX) |
| SoC | MediaTek MT7981A |
| Wi-Fi | MT7976 (2.4 GHz + 5 GHz) |
| Modem | Quectel RM520N-GL (5G NR Sub-6) over PCIe MHI |
| Storage | 8 GB eMMC |
| RAM | 1 GB DDR4 |

## Prerequisites (build host)

  * Linux x86_64 (build also works on aarch64; see below)
  * ~25 GB free disk for the build tree, dl/, build_dir/ and staging_dir/
  * 8+ GB RAM (toolchain build needs ~6 GB peak, android-tools' BoringSSL
    + fmt are also memory-hungry)
  * The standard OpenWrt build dependencies — see
    https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem
    On Debian/Ubuntu:
    ```
    sudo apt install build-essential clang flex bison g++ gawk \
        gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
        python3-distutils rsync unzip zlib1g-dev file wget
    ```
  * `golang` (≥ 1.21) on **aarch64** hosts only — the in-tree
    `golang-bootstrap` doesn't compile on arm64. On x86_64 you can leave
    `CONFIG_GOLANG_BUILD_BOOTSTRAP=y` and skip this step.

## Build

The build supports two variants, selected by argument to `prepare.sh`
(or `build.sh`, the one-shot driver):

  * **`private`** — image with builder-internal extras. Composes the
    rootfs from `files-common/` + `files-private/`, where the latter
    is a per-builder slot whose contents are gitignored so each
    builder keeps their CA / feed-signing pubkey / internal config
    out of the public repo (see `files-private/README.md`). Also
    bakes in `telegraf-full` for metrics push.

  * **`public`** — vanilla image suitable for anyone with the same
    hardware (GL-X3000 + RM520N-GL). Same modem stack, same custom
    packages (qfirehose, quectel-5g-tools, adb, LuCI bundle), no
    private overlay, no telegraf.

```
git clone https://github.com/vjt/openwrt-glinet-x3000.git
cd openwrt-glinet-x3000

# One-shot: prepare + make + relocate output to bin-x3000-<variant>/
./x3000/build.sh private          # bad.ass fleet image
./x3000/build.sh public           # public image
./x3000/build.sh public -- V=s    # forward extra args to make

# Or step-by-step (artifacts land in bin/ — overwritten on every build):
./x3000/prepare.sh public
make -j$(nproc)
```

`prepare.sh` is idempotent — re-run it any time `x3000/custom-feeds.txt`
changes (e.g. you bumped a custom package) or you switch variants and
it will refresh the clones, refresh the symlinks under `feeds-local/`,
recompose `.config` from `x3000/config.common + x3000/config.<variant>`,
and recompose `files/` from `x3000/files-common/ + x3000/files-<variant>/`.
The active variant is recorded in `.x3000-variant`.

After `build.sh` finishes the artifacts land under

```
bin-x3000-<variant>/targets/mediatek/filogic/
├── openwrt-mediatek-filogic-glinet_gl-x3000-squashfs-sysupgrade.bin
├── openwrt-mediatek-filogic-glinet_gl-x3000-squashfs-factory.bin
├── openwrt-mediatek-filogic-glinet_gl-x3000.manifest
└── …
```

(Plain `make` without `BIN_DIR=` writes to the default `bin/`, which
gets overwritten by the next build of the other variant — use
`build.sh` if you want both variants to coexist on disk.)

Use `sysupgrade.bin` for an in-place upgrade from a router that's
already running OpenWrt; use `factory.bin` only via stock recovery
mode. The GL.iNet stock U-Boot rejects factory headers via the web
UI — it expects a sysupgrade-style image even on the first flash —
so plan accordingly.

## On aarch64 build hosts

`x3000/config.common` already disables `CONFIG_GOLANG_BUILD_BOOTSTRAP`
and sets `GOLANG_EXTERNAL_BOOTSTRAP_ROOT="/usr/local/go"`. Install Go
≥ 1.21 there before running `prepare.sh`:

```
wget https://go.dev/dl/go1.23.5.linux-arm64.tar.gz
sudo tar -C /usr/local -xzf go1.23.5.linux-arm64.tar.gz
```

If your Go install lives elsewhere, edit
`CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT` in `x3000/config.common` before
the `prepare.sh` run that composes it into `.config`.

## Pinning custom packages

`x3000/custom-feeds.txt` defaults to `master` for every custom repo,
which tracks fixes — handy during development but not reproducible.
For production builds, replace each `master` with a commit SHA, e.g.

```
android-tools https://github.com/vjt/openwrt-android-tools.git f24c199 openwrt/android-tools
```

Then `./x3000/prepare.sh` will fetch the repos and check out exactly
those SHAs.

## Layout

```
x3000/
├── README.md           This file.
├── prepare.sh          Variant-aware tree setup: feeds-local/, feeds.conf,
                        composes .config and files/ from common + variant
                        sources, applies x3000/patches/ with `-F 0`.
├── build.sh            One-shot driver: prepare.sh + make with a
                        variant-specific BIN_DIR (bin-x3000-<variant>/).
├── feeds.conf          Verbatim copy installed at /feeds.conf
                        (with feeds-local/ rewritten to absolute path).
├── custom-feeds.txt    Repo list driving prepare.sh.
├── config.common       Shared build-config overlay (target + the bulk of
                        package selections).
├── config.private      Private-only delta (telegraf-full, etc.).
├── config.public       Public-only delta (explicit unsets for telegraf).
├── files-common/       Rootfs overlay shipped in every variant.
├── files-private/      Rootfs overlay only in private. Per-builder slot:
                        only .gitkeep is tracked, all contents are
                        gitignored, so each builder keeps their internal
                        CA / feed-signing pubkey / customfeeds.list
                        local. Empty in a fresh clone — populate before
                        building private if you need any of those.
├── files-public/       Rootfs overlay only in public (currently empty).
└── patches/            Unified diffs applied to feeds/ files after
                        `feeds install -a`. patch is invoked with
                        --forward and -F 0 so the loop is idempotent
                        AND a context drift is a hard fail. Currently:
                          * 0001-modemmanager-tty-honour-ignore-tty.patch
                          * 0002-curl-disable-brotli-autodetect.patch
target/linux/generic/pending-6.12/
└── gl-x3000-quectel-pci-id.patch   Kernel patch (commit 8cc71da72a).
target/linux/mediatek/dts/
└── mt7981a-glinet-gl-x3000-xe3000-common.dtsi   pcie_port_pm=off
                                                 (commit 4087faad55).
```

`prepare.sh` writes its composed outputs to `/.config` and `/files/`
(both gitignored), and records the active variant in `/.x3000-variant`.

## Post-flash modem config

Sysupgrade preserves `/etc/config/*`, so the `network.wwan` section
ends up whatever the previous image set it to. For a clean MM
attach, set it manually after first boot:

```sh
uci set network.wwan.proto='modemmanager'
uci set network.wwan.device="$(readlink -f /sys/class/wwan/wwan0mbim0/device/../..)"
uci set network.wwan.apn='<your-apn>'
uci set network.wwan.auth='none'
uci set network.wwan.iptype='ipv4v6'
uci commit network
ifup wwan
```

The `device` field must point at the modem's PHYSICAL parent
(PCI device for MHI, USB device for cdc-wdm) — not its wwan/usbmisc
child. The `readlink ... /../..` form above resolves to the right
place for the GL-X3000's PCIe-attached RM520N.
