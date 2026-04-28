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
  * **speedtest-go**, **telegraf-full** (every input/output plugin
    compiled in — drop to the `telegraf` small variant if you want a
    smaller binary and only need the plugins enumerated in the feed
    Makefile's `TELEGRAF_SMALL_PLUGINS`), **wifi-dethrash-collector**.
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

```
git clone https://github.com/vjt/openwrt-glinet-x3000.git
cd openwrt-glinet-x3000
./x3000/prepare.sh
make -j$(nproc)              # add V=s for verbose
```

`prepare.sh` is idempotent — re-run it any time `x3000/custom-feeds.txt`
changes (e.g. you bumped a custom package) and it will refresh the
clones, refresh the symlinks under `feeds-local/`, and re-apply the
`.config-x3000` overlay.

After the build finishes the artifacts land under

```
bin/targets/mediatek/filogic/
├── openwrt-mediatek-filogic-glinet_gl-x3000-squashfs-sysupgrade.bin
├── openwrt-mediatek-filogic-glinet_gl-x3000-squashfs-factory.bin
├── openwrt-mediatek-filogic-glinet_gl-x3000.manifest
└── …
```

Use `sysupgrade.bin` for an in-place upgrade from a router that's
already running OpenWrt; use `factory.bin` only via stock recovery
mode. The GL.iNet stock U-Boot rejects factory headers via the web
UI — it expects a sysupgrade-style image even on the first flash —
so plan accordingly.

## On aarch64 build hosts

`.config-x3000` already disables `CONFIG_GOLANG_BUILD_BOOTSTRAP` and
sets `GOLANG_EXTERNAL_BOOTSTRAP_ROOT="/usr/local/go"`. Install Go
≥ 1.21 there before running `prepare.sh`:

```
wget https://go.dev/dl/go1.23.5.linux-arm64.tar.gz
sudo tar -C /usr/local -xzf go1.23.5.linux-arm64.tar.gz
```

If your Go install lives elsewhere, edit
`CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT` in `.config-x3000` before the
`prepare.sh` run that copies it into `.config`.

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
.config-x3000           Build-config overlay (target + package selections).
                        Copied to .config by prepare.sh.
x3000/
├── README.md           This file.
├── prepare.sh          Sets up feeds-local/, feeds.conf, .config; applies
                        x3000/patches/ against feed files with `-F 0` so
                        upstream drift fails loud.
├── feeds.conf          Verbatim copy installed at /feeds.conf
                        (with feeds-local/ rewritten to absolute path).
├── custom-feeds.txt    Repo list driving prepare.sh.
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
