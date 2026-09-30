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

# fx_www: one http server for $TEST_TMP/www (the fake Pages site under
# feed/, the fake upstream feed under upstream/). Sets FX_URL.
fx_www() {
    mkdir -p "$TEST_TMP/www"
    feed_serve "$TEST_TMP/www"
    FX_PIDS+=("$FEED_SERVE_PID")
    export FX_URL="$FEED_SERVE_URL"
}

# fx_pages_remote: a bare gh-pages remote whose post-receive hook
# deploys the pushed tree into $TEST_TMP/www/feed — a local GitHub
# Pages. Seeded like the real one after the spike. Needs fx_www.
fx_pages_remote() {
    local bare="$TEST_TMP/pages.git" seed="$TEST_TMP/pages-seed" site="$TEST_TMP/www/feed"
    git init -q --bare "$bare"
    cat > "$bare/hooks/post-receive" <<EOF
#!/bin/sh
rm -rf "$site" && mkdir -p "$site" && git --git-dir="$bare" archive gh-pages | tar -x -C "$site"
EOF
    chmod +x "$bare/hooks/post-receive"
    mkdir -p "$seed/spike"
    echo probe > "$seed/spike/x3000-feed-probe-1.0-r1.apk"
    touch "$seed/.nojekyll"
    git -C "$seed" init -q -b gh-pages
    git -C "$seed" add -A
    git -C "$seed" commit -q -m spike
    git -C "$seed" push -q "$bare" gh-pages 2>/dev/null
    export FX_PAGES_BARE="$bare" FEED_GIT_URL="file://$bare" FEED_BASE_URL="$FX_URL/feed"
}

fx_pages_sha() {
    git --git-dir="$FX_PAGES_BARE" rev-parse gh-pages
}

# fx_gh_stub: a fake gh on PATH. The latest Pages build is the bare
# remote's gh-pages commit (status $FX_PAGES_STATUS, default built);
# releases live in $TEST_TMP/releases/<tag>/. Calls go to $TEST_TMP/gh.log.
fx_gh_stub() {
    mkdir -p "$TEST_TMP/stubbin" "$TEST_TMP/releases"
    cat > "$TEST_TMP/stubbin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$TEST_TMP/gh.log"
rel="$TEST_TMP/releases"
case "$1" in
    api)
        case "$2" in
            */pages/builds/latest)
                printf '{"status":"%s","commit":"%s","error":{"message":"fixture"}}\n' \
                    "${FX_PAGES_STATUS:-built}" "$(git --git-dir="$FX_PAGES_BARE" rev-parse gh-pages)"
                ;;
            */releases/tags/*)
                if [[ -d "$rel/${2##*/}" ]]; then
                    echo '{}'
                else
                    echo 'gh: Not Found (HTTP 404)' >&2
                    exit 1
                fi
                ;;
            *) echo "fake gh: unhandled api $2" >&2; exit 1 ;;
        esac
        ;;
    release)
        sub="$2"; tag="$3"; shift 3
        case "$sub" in
            create|upload)
                if [[ "$sub" == upload && ! -d "$rel/$tag" ]]; then
                    echo "release not found" >&2
                    exit 1
                fi
                mkdir -p "$rel/$tag"
                for a in "$@"; do
                    if [[ -f "$a" && "$a" == */bin-x3000-* ]]; then
                        cp "$a" "$rel/$tag/"
                    fi
                done
                ;;
            download)
                dest=.
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        -D) dest="$2"; shift 2 ;;
                        *) shift ;;
                    esac
                done
                [[ -d "$rel/$tag" ]] || { echo "release not found" >&2; exit 1; }
                mkdir -p "$dest"
                cp "$rel/$tag"/* "$dest"/
                ;;
            *) echo "fake gh: unhandled release $sub" >&2; exit 1 ;;
        esac
        ;;
    *) echo "fake gh: unhandled $*" >&2; exit 1 ;;
esac
EOF
    chmod +x "$TEST_TMP/stubbin/gh"
    export PATH="$TEST_TMP/stubbin:$PATH"
}

# fx_upstream: a stand-in for the OpenWrt feeds an image lists in
# distfeeds.list — libc and wireguard-tools (which needs kmod-wireguard,
# like the real one) — signed by an "upstream" key the image trusts.
# Needs fx_www. Exports what fx_build_outputs bakes into the image.
fx_upstream() {
    local dir="$TEST_TMP/www/upstream"
    fx_key "$TEST_TMP/upstream-key"
    fx_apk "$dir" libc 1.2.5-r5
    fx_apk "$dir" wireguard-tools 1.0.20260223-r1 "kmod-wireguard libc"
    feed_reindex "$dir" "$TEST_TMP/upstream-key"
    export FX_UPSTREAM_URL="$FX_URL/upstream" FX_UPSTREAM_PUB="$TEST_TMP/upstream-key/public-key.pem"
}
