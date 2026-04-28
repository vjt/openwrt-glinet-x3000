# GL.iNet GL-X3000 (Spitz AX) — vanilla OpenWrt build

This is a fork of the OpenWrt 25.12 stable branch that produces a
working sysupgrade image for the GL.iNet GL-X3000, including the
custom-package layer needed to drive the device's Quectel RM520N-GL
5G modem on the mainline `mhi_pci_generic` + `cdc_mbim` path.

The fork carries three commits on top of upstream:

  1. A pending kernel patch that teaches `mhi_pci_generic` about the
     RM520N-GL's Qualcomm-subvendor PCI ID — without it the modem
     never enumerates as an MHI device.
  2. A DTSI tweak that sets `pcie_port_pm=off` in the kernel cmdline
     so the PCIe root port can't take the modem into D3hot during
     MHI's startup ramp (otherwise the host hits a CmpltTO/AER storm
     that only a host reboot recovers from).
  3. `.config-x3000` — the persistent build-config overlay that pins
     the device target, packages, and a couple of build-system knobs.

The custom-package layer (adb with the bInterfaceNumber claim fix,
qfirehose 1.4.17, quectel-5g-tools, brotli, wifi-dethrash-collector)
lives in separate GitHub repositories; `x3000/prepare.sh` clones them
and wires them into a `feeds-local/` symlink dir before the build.

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
    fmt is also memory-hungry)
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
mode (the GL.iNet stock U-Boot rejects factory headers via the web UI
— it expects a sysupgrade-style image even on the first flash).

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
├── feeds.conf          Verbatim copy installed at /feeds.conf.
└── custom-feeds.txt    Repo list driving prepare.sh.
target/linux/generic/pending-6.12/
└── gl-x3000-quectel-pci-id.patch   Kernel patch (commit 8cc71da72a).
target/linux/mediatek/dts/
└── mt7981a-glinet-gl-x3000-xe3000-common.dtsi   pcie_port_pm=off
                                                 (commit 4087faad55).
```
