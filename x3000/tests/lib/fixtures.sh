# x3000/tests/lib/fixtures.sh — builders for what the tests need: keys,
# packages, images, feeds, remotes, a fake gh. Everything lives under
# $TEST_TMP, which run.sh creates per test and removes afterwards.

source "$X3000_REAL_ROOT/x3000/lib/feed.sh"

# The lib's temp files die with the test.
export FEED_TMPDIR="$TEST_TMP"

# Keep the user's git config (signing, hooks, default branch) out.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

FX_KVER_DEFAULT='6.12.103~0123456789abcdef0123456789abcdef-r1'

# Background processes (http servers) to stop when the test exits.
FX_PIDS=()
fx_cleanup() {
    local p
    for p in "${FX_PIDS[@]}"; do
        kill "$p" 2>/dev/null || true
    done
}
trap fx_cleanup EXIT

# fx_key DIR: a fresh prime256v1 key pair, named like the tree's.
fx_key() {
    mkdir -p "$1"
    openssl ecparam -name prime256v1 -genkey -noout -out "$1/private-key.pem" 2>/dev/null
    openssl ec -in "$1/private-key.pem" -pubout -out "$1/public-key.pem" 2>/dev/null
}

# fx_prepare_tree DIR: a tree in which prepare.sh and build.sh run end
# to end without network or toolchain — a copy of the real x3000/ with
# no custom feeds and no patches, a stub scripts/feeds, and a stub make
# on PATH that logs its arguments and creates any BIN_DIR= it is given.
fx_prepare_tree() {
    local dir="$1"
    mkdir -p "$dir/x3000" "$dir/scripts" "$TEST_TMP/stubbin"
    cp -a "$X3000_REAL_ROOT/x3000/." "$dir/x3000/"
    rm -rf "$dir/x3000/files-private" "$dir/x3000/patches"
    rm -f "$dir/x3000"/*.local
    mkdir -p "$dir/x3000/files-private"
    printf '# no custom feeds in fixtures\n' > "$dir/x3000/custom-feeds.txt"
    printf '#!/bin/sh\nexit 0\n' > "$dir/scripts/feeds"
    chmod +x "$dir/scripts/feeds"
    cat > "$TEST_TMP/stubbin/make" <<'STUB'
#!/bin/sh
echo "make $*" >> "$TEST_TMP/make.log"
for a in "$@"; do
    case "$a" in BIN_DIR=*) mkdir -p "${a#BIN_DIR=}" ;; esac
done
STUB
    chmod +x "$TEST_TMP/stubbin/make"
    export PATH="$TEST_TMP/stubbin:$PATH"
}

# fx_apk OUTDIR NAME VERSION [DEPENDS] [ORIGIN]: an empty package with
# the metadata the feed code reads. No files: nothing ever installs it.
fx_apk() {
    local out="$1" name="$2" ver="$3" deps="${4:-}" origin="${5:-feeds/base/fixture}"
    local -a args=(--info "name:$name" --info "version:$ver" --info "arch:$FEED_ARCH" --info "origin:$origin")
    if [[ -n "$deps" ]]; then
        args+=(--info "depends:$deps")
    fi
    mkdir -p "$out"
    "$FEED_HOST_BIN/apk" mkpkg "${args[@]}" --output "$out/$name-$ver.apk" >/dev/null
}

# fx_root DIR: a tree root with a signing key and a scripts/getver.sh
# stub printing the revision an image built from it must carry.
fx_root() {
    fx_key "$1"
    mkdir -p "$1/scripts"
    printf '#!/bin/sh\necho r100-fixture0001\n' > "$1/scripts/getver.sh"
    chmod +x "$1/scripts/getver.sh"
}

# fx_sysupgrade ROOTDIR OUT REVISION: a sysupgrade tar shaped like the
# real one (CONTROL, kernel, root squashfs) with fwtool metadata
# appended, unless FX_NO_METADATA is set.
fx_sysupgrade() {
    local rootdir="$1" out="$2" rev="$3" st
    st="$(mktemp -d -p "$TEST_TMP")"
    mkdir -p "$st/$FEED_SYSUPGRADE_SUBDIR"
    "$FEED_HOST_BIN/mksquashfs4" "$rootdir" "$st/$FEED_SYSUPGRADE_SUBDIR/root" \
        -nopad -noappend -root-owned -quiet >/dev/null
    echo "BOARD=glinet_gl-x3000" > "$st/$FEED_SYSUPGRADE_SUBDIR/CONTROL"
    : > "$st/$FEED_SYSUPGRADE_SUBDIR/kernel"
    tar -C "$st" -cf "$out" "$FEED_SYSUPGRADE_SUBDIR"
    if [[ -z "${FX_NO_METADATA:-}" ]]; then
        printf '{"metadata_version":"1.1","version":{"dist":"OpenWrt","revision":"%s","board":"glinet_gl-x3000"}}' \
            "$rev" > "$st/meta.json"
        "$FEED_HOST_BIN/fwtool" -I "$st/meta.json" "$out"
    fi
    rm -rf "$st"
}

# fx_build_outputs ROOT TAG: what `build.sh public --release TAG` leaves
# behind, in miniature. See the Task 5 interface list for the knobs.
fx_build_outputs() {
    local root="$1" tag="$2"
    local bin="$root/bin-x3000-public" custom="$root/bin/packages/$FEED_ARCH/custom"
    local kver="${FX_KVER:-$FX_KVER_DEFAULT}" img rev
    rm -rf "$bin" "$root/bin/packages"
    mkdir -p "$bin/packages" "$custom"

    fx_apk "$bin/packages" kernel "$kver" libc feeds/base/kernel/linux
    fx_apk "$bin/packages" kmod-tun 6.12.103-r1 "kernel=$kver" feeds/base/kernel/linux
    fx_apk "$bin/packages" kmod-wireguard 6.12.103-r1 "kernel=$kver" feeds/base/kernel/linux
    if [[ -n "${FX_FOREIGN_KMOD:-}" ]]; then
        fx_apk "$bin/packages" kmod-foreign 6.12.103-r1 \
            "kernel=6.12.103~ffffffffffffffffffffffffffffffff-r1" feeds/base/kernel/linux
    fi

    fx_apk "$custom" quectel-5g-tools "${FX_CUSTOM_VER:-1.10.2-r1}" "${FX_CUSTOM_DEPS:-libc}" \
        .build-deps/quectel-5g-tools/openwrt/quectel-5g-tools
    fx_apk "$custom" libbrotlicommon 1.1.0-r1 libc .build-deps/openwrt-android-tools/openwrt/brotli
    # From a custom-feeds.private.local repo: must never be published.
    fx_apk "$custom" secret-pkg 1.0-r1 libc .build-deps/private-stuff/openwrt/secret-pkg

    {
        echo "base-files - 1715~fixture"
        echo "kernel - $kver"
        echo "kmod-tun - 6.12.103-r1"
        if [[ -n "${FX_TELEGRAF:-}" ]]; then
            echo "telegraf-full - 1.39.1-r1"
        fi
    } > "$(feed_manifest_path "$bin")"

    rev="$(cd "$root" && ./scripts/getver.sh)"
    img="$(mktemp -d -p "$TEST_TMP")"
    mkdir -p "$img/etc/apk/keys" "$img/etc/apk/repositories.d"
    echo "$FEED_ARCH" > "$img/etc/apk/arch"
    cp "${FX_IMAGE_PUB:-$root/public-key.pem}" "$img/etc/apk/keys/public-key.pem"
    if [[ -n "${FX_UPSTREAM_PUB:-}" ]]; then
        cp "$FX_UPSTREAM_PUB" "$img/etc/apk/keys/upstream.pem"
    fi
    if [[ -n "${FX_UPSTREAM_URL:-}" ]]; then
        echo "$FX_UPSTREAM_URL/packages.adb" > "$img/etc/apk/repositories.d/distfeeds.list"
    fi
    if [[ -z "${FX_NO_LIST:-}" ]]; then
        feed_repo_list "$tag" > "$img/etc/apk/repositories.d/$FEED_LIST_NAME"
    fi
    printf "DISTRIB_ID='OpenWrt'\nDISTRIB_REVISION='%s'\n" \
        "$([[ -n "${FX_STALE_BASEFILES:-}" ]] && echo r1-stale || echo "$rev")" > "$img/etc/openwrt_release"
    fx_sysupgrade "$img" "$(feed_sysupgrade_path "$bin")" "$rev"
    rm -rf "$img"

    echo preloader > "$bin/$FEED_IMAGE_PREFIX-preloader.bin"
    echo fip > "$bin/$FEED_IMAGE_PREFIX-bl31-uboot.fip"
    echo "${FX_FEED_TAG:-$tag}" > "$bin/FEED_TAG"
}

# fx_feeds_txt FILE: a custom-feeds.txt whose origins are those of the
# public packages fx_build_outputs builds (not secret-pkg's).
fx_feeds_txt() {
    cat > "$1" <<'EOF'
# fixture custom feeds
quectel-5g-tools https://github.com/vjt/quectel-5g-tools.git master openwrt/quectel-5g-tools

brotli https://github.com/vjt/openwrt-android-tools.git master openwrt/brotli   # shares the clone
EOF
}
