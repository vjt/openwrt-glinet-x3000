# GL.iNet GL-X3000 (Spitz AX) — vanilla OpenWrt build

A working OpenWrt 25.12 image for the GL.iNet GL-X3000 (Spitz AX),
including the kernel and userspace pieces needed to drive the
Quectel RM520N-GL 5G modem on the mainline `mhi_pci_generic` +
`cdc_mbim` path with no proprietary out-of-tree bits.

## Why this fork exists

The GL.iNet stock firmware ships an old OpenWrt 21.02 + kernel 5.4
+ a vendor-patched `pcie_mhi` driver that's never been upstreamed.
Vanilla OpenWrt 25.12 (kernel 6.12) supports the rest of the device
out of the box but needs three small fixes before the modem actually
comes up and stays up under load:

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

3. **`proto mbim` is one-shot — it doesn't notice when the carrier
   tears down a PDN.** With no ModemManager (we don't ship it; see
   below), nothing is left listening on the MBIM control channel
   after `umbim connect` exits. Italian carriers like TIM routinely
   recycle the PDN on idle / RAT change / session refresh, leaving
   `wwan0` UP with a stale IP and silent traffic loss. Our
   `quectel-5g-tools` package ships a small libmbim-glib daemon
   (`mbim-watchdog`) that subscribes to BASIC_CONNECT/CONNECT
   indications via `mbim-proxy` and reissues `ifup wwan` whenever
   the modem reports the Internet context as deactivated. Plus
   `5g-led-bars`, a Lua daemon that drives the four panel signal
   LEDs from PCC RSRP (preferring NR5G when present), since the
   kernel's netdev trigger is binary on/off and pegs the bars at
   4/4 whenever `wwan0` has carrier.

## What's different from a stock OpenWrt 25.12 build

Three commits sit on top of upstream `openwrt-25.12`:

  * `mhi_pci_generic: claim Quectel RM520N-GL with Qualcomm subvendor IDs`
  * `mediatek: glinet gl-x3000: disable PCIe runtime PM via pcie_port_pm=off`
  * `x3000: persistent build configuration for the bad.ass fleet`

Plus the build-prep machinery under `x3000/`.

The build config drops a few things that upstream's GL-X3000 device
recipe pulls in:

  * **ModemManager + libqmi + libqrtr-glib + dbus + luci-proto-{modemmanager,qmi}.**
    MM holds /dev/ttyUSB2 (or its MBIM control device equivalent)
    exclusively, blocking `quectel-5g-tools`' read-only AT clients,
    and its dbus / glib2 / libqrtr-glib chain is much heavier than
    the routes we actually use. Dropped in favour of `proto mbim` +
    `mbim-watchdog`.
  * **samba4-server + luci-app-samba4.** The fleet doesn't share
    files over SMB.
  * **kmod-scsi-core + kmod-usb-storage.** No USB storage use case.

And adds:

  * **adb + fastboot** (nmeum/android-tools 35.0.2 with a small patch
    fixing the libusb claim bug for non-contiguous USB interface
    numbers — the RM520N publishes interfaces 0,1,2,3,5 and the
    upstream client iterates by array index).
  * **qfirehose** (vjt fork pinned at 1.4.17; upstream 1.4.11 bricks
    RM520N).
  * **quectel-5g-tools** (Lua AT helpers `5g-info`, `5g-monitor`,
    `5g-lock`, `modem-debug`; the `5g-led-bars` procd daemon driving
    the panel signal LEDs from RSRP; the `mbim-watchdog` libmbim-glib
    daemon for indication-driven PDN reconnect; a Prometheus
    collector).
  * **pciutils + usbutils** (lspci / lsusb baked in for diagnosing
    modem PCIe / USB topology).
  * **MBIM stack**: umbim, libmbim, mbim-utils, glib2,
    kmod-usb-net-cdc-mbim, luci-proto-mbim.
  * **speedtest-go**, **telegraf**, **wifi-dethrash-collector**.

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
├── prepare.sh          Sets up feeds-local/, feeds.conf, .config.
├── feeds.conf          Verbatim copy installed at /feeds.conf
                        (with feeds-local/ rewritten to absolute path).
└── custom-feeds.txt    Repo list driving prepare.sh.
target/linux/generic/pending-6.12/
└── gl-x3000-quectel-pci-id.patch   Kernel patch (commit 8cc71da72a).
target/linux/mediatek/dts/
└── mt7981a-glinet-gl-x3000-xe3000-common.dtsi   pcie_port_pm=off
                                                 (commit 4087faad55).
```
