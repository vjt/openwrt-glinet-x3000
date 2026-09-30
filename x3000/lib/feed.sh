# x3000/lib/feed.sh — shared checks and helpers for the public apk feed
# at https://vjt.github.io/x3000-feed/ (kmods per release tag + rolling
# custom packages). Sourced by prepare.sh, release.sh, publish-feed.sh
# and x3000/tests/, so that every check exists in exactly one place.
# "Cutting a release" in x3000/README.md has the workflow.
#
# Everything here fails closed: a helper that cannot prove its check
# passed calls feed_die. Callers run with `set -euo pipefail` and call
# these functions as plain statements (set -e is suspended inside
# conditions, and in every function they call).

FEED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Overridable so the tests can point them at fixtures. prepare.sh bakes
# FEED_BASE_URL into the image and release.sh checks the image against
# its own value, so a stray override fails the artifact check.
: "${FEED_BASE_URL:=https://vjt.github.io/x3000-feed}"
: "${FEED_GIT_URL:=git@github.com:vjt/x3000-feed.git}"
: "${FEED_GH_REPO:=vjt/x3000-feed}"
: "${FEED_KEY_REPO:=vjt/x3000-feed-key}"
: "${RELEASE_GH_REPO:=vjt/openwrt-glinet-x3000}"
: "${FEED_HOST_BIN:=$FEED_ROOT/staging_dir/host/bin}"
: "${FEED_TIMEOUT:=600}"
: "${FEED_POLL_INTERVAL:=5}"

FEED_ARCH=aarch64_cortex-a53
FEED_KEEP_TAGS=3
FEED_KEEP_VERSIONS=2
FEED_IMAGE_PREFIX=openwrt-mediatek-filogic-glinet_gl-x3000
FEED_SYSUPGRADE_SUBDIR=sysupgrade-glinet_gl-x3000
FEED_LIST_NAME=x3000feed.list

feed_log() {
    echo "==> $*" >&2
}

feed_warn() {
    echo "WARNING: $*" >&2
}

feed_die() {
    echo "FATAL: $*" >&2
    exit 1
}

# Temp files go under $FEED_TMPDIR when the caller set one (release.sh
# and publish-feed.sh remove it on exit).
feed_mktemp() {
    mktemp -p "${FEED_TMPDIR:-${TMPDIR:-/tmp}}" "$@"
}

feed_hostbin() {
    local bin="$FEED_HOST_BIN/$1"
    [[ -x "$bin" ]] || feed_die "missing host tool $bin (build the tree once: host tools live in staging_dir/host/bin)"
    printf '%s\n' "$bin"
}

# The tree's apk (3.x), not whatever the host has.
feed_apk() {
    local apk
    apk="$(feed_hostbin apk)"
    "$apk" "$@"
}

# The tag becomes a URL path segment and a git ref.
feed_check_tag() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || feed_die "bad tag '${1:-}': letters, digits, '.', '_' and '-' only, not starting with '-' or '.'"
}

# The two feed lines an image built for <tag> carries in
# /etc/apk/repositories.d/x3000feed.list.
feed_repo_list() {
    local tag="$1" base="${2:-$FEED_BASE_URL}"
    printf '%s/kmods/%s/packages.adb\n' "$base" "$tag"
    printf '%s/custom/packages.adb\n' "$base"
}

# Normalised "<name> <url> <ref> <subdir>" lines of a custom-feeds list
# (x3000/custom-feeds.txt format): comments and blank lines dropped.
feed_list_entries() {
    local list="$1" raw_line line name url ref subdir
    [[ -f "$list" ]] || feed_die "missing $list"
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line="${raw_line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        line="${line%"${line##*[![:space:]]}"}"   # rtrim
        [[ -z "$line" ]] && continue
        read -r name url ref subdir <<< "$line"
        [[ -n "${subdir:-}" ]] || feed_die "malformed line in $list: $raw_line"
        printf '%s %s %s %s\n' "$name" "$url" "$ref" "$subdir"
    done < "$list"
}

# The `origin` the build records for packages of each list line:
# prepare.sh clones <url> into .build-deps/<repo-basename>/ and links
# <subdir> into feeds-local/. One per line, sorted, unique.
feed_custom_origins() {
    local entries name url ref subdir
    entries="$(feed_list_entries "$1")"
    while read -r name url ref subdir; do
        [[ -n "$name" ]] || continue
        printf '.build-deps/%s/%s\n' "$(basename "${url%.git}")" "$subdir"
    done <<< "$entries" | sort -u
}

# Release builds must be signed with private-key.pem: every image we
# ever shipped trusts its public half. Without it, package/Makefile
# silently mints a new key, and the feed signed with that one is
# UNTRUSTED on every device out there.
feed_check_key() {
    local root="$1" derived
    if [[ ! -f "$root/private-key.pem" ]]; then
        feed_die "$root/private-key.pem is missing: a release build would mint a new key that no shipped image trusts. Restore it:
    gh repo clone $FEED_KEY_REPO /tmp/x3000-feed-key
    cp /tmp/x3000-feed-key/private-key.pem /tmp/x3000-feed-key/public-key.pem '$root/'"
    fi
    [[ -f "$root/public-key.pem" ]] || feed_die "$root/public-key.pem is missing (restore it from $FEED_KEY_REPO)"
    derived="$(openssl ec -in "$root/private-key.pem" -pubout 2>/dev/null)" \
        || feed_die "$root/private-key.pem is not a readable EC private key"
    [[ "$derived" == "$(cat "$root/public-key.pem")" ]] \
        || feed_die "$root/public-key.pem does not derive from $root/private-key.pem"
}

# "<name>\t<version>\t<origin>\t<depends, space-separated>" for one .apk.
feed_pkg_tsv() {
    local json
    json="$(feed_apk adbdump --format json "$1")" || feed_die "cannot read package $1"
    jq -r '.info | [.name, .version, (.origin // ""), ((.depends // []) | join(" "))] | @tsv' <<< "$json"
}

# The same fields, one line per package of an index (packages.adb).
feed_index_tsv() {
    local json
    json="$(feed_apk adbdump --format json "$1")" || feed_die "cannot read index $1"
    jq -r '.packages[]? | [.name, .version, (.origin // ""), ((.depends // []) | join(" "))] | @tsv' <<< "$json"
}

# Dies unless adb is signed by pubkey — the same trust decision a device
# makes with only that key in /etc/apk/keys/.
feed_verify_index() {
    local adb="$1" pubkey="$2" keys out
    keys="$(feed_mktemp -d)"
    cp "$pubkey" "$keys/"
    # --keys-dir must be absolute (mktemp's is): a relative one resolves
    # under --root, and every signature then reads UNTRUSTED.
    if ! out="$(feed_apk --keys-dir "$keys" verify "$adb" 2>&1)" || grep -qi untrusted <<< "$out"; then
        rm -rf "$keys"
        feed_die "$adb is not signed by $pubkey: $out"
    fi
    rm -rf "$keys"
}

# Signs dir/*.apk into dir/packages.adb with the tree key, using the
# build system's own recipe (package/Makefile), then proves the result
# verifies with the tree's public key.
feed_reindex() {
    local dir="$1" root="$2"
    compgen -G "$dir/*.apk" >/dev/null || feed_die "no .apk in $dir to index"
    rm -f "$dir/packages.adb"
    ( cd "$dir" && feed_apk mkndx \
          --root "$root" \
          --keys-dir "$root" \
          --allow-untrusted \
          --sign "$root/private-key.pem" \
          --output packages.adb \
          ./*.apk >/dev/null ) \
        || feed_die "apk mkndx failed in $dir"
    feed_verify_index "$dir/packages.adb" "$root/public-key.pem"
}

feed_sysupgrade_path() {
    printf '%s/%s-squashfs-sysupgrade.bin\n' "$1" "$FEED_IMAGE_PREFIX"
}

feed_manifest_path() {
    printf '%s/%s.manifest\n' "$1" "$FEED_IMAGE_PREFIX"
}

# The rootfs squashfs out of a sysupgrade tar.
feed_extract_rootfs() {
    local bin="$1" out="$2"
    if ! tar -xOf "$bin" "$FEED_SYSUPGRADE_SUBDIR/root" > "$out" 2>/dev/null || [[ ! -s "$out" ]]; then
        feed_die "$bin has no $FEED_SYSUPGRADE_SUBDIR/root"
    fi
}

feed_rootfs_cat() {
    local sqfs="$1" path="$2" unsq
    unsq="$(feed_hostbin unsquashfs4)"
    "$unsq" -cat "$sqfs" "$path" 2>/dev/null || feed_die "image has no /$path"
}

# Step 3, on the image itself rather than the files/ it was built from:
# it comes from `build.sh --release <tag>`, points at the feed for <tag>,
# trusts our key, is the public variant, and carries the version of the
# tree it was built from.
feed_check_artifact() {
    local bindir="$1" tag="$2" root="$3"
    local bin manifest sqfs got want meta rev want_rev fwtool
    [[ -f "$bindir/FEED_TAG" ]] || feed_die "$bindir/FEED_TAG missing: $bindir was not built with --release"
    got="$(cat "$bindir/FEED_TAG")"
    [[ "$got" == "$tag" ]] || feed_die "$bindir/FEED_TAG says '$got', expected '$tag'"
    bin="$(feed_sysupgrade_path "$bindir")"
    manifest="$(feed_manifest_path "$bindir")"
    [[ -f "$bin" ]] || feed_die "missing $bin"
    [[ -f "$manifest" ]] || feed_die "missing $manifest"
    # x3000/config.public strips telegraf; r2, r6 and r7 shipped the
    # private image by mistake.
    if grep -q '^telegraf' "$manifest"; then
        feed_die "$manifest lists telegraf: this is the private variant"
    fi

    sqfs="$(feed_mktemp)"
    feed_extract_rootfs "$bin" "$sqfs"
    got="$(feed_rootfs_cat "$sqfs" "etc/apk/repositories.d/$FEED_LIST_NAME")"
    want="$(feed_repo_list "$tag")"
    [[ "$got" == "$want" ]] || feed_die "image $FEED_LIST_NAME does not point at tag $tag:"$'\n'"$got"
    got="$(feed_rootfs_cat "$sqfs" etc/apk/keys/public-key.pem)"
    want="$(cat "$root/public-key.pem")"
    [[ "$got" == "$want" ]] || feed_die "image does not trust $root/public-key.pem"

    # scripts/getver.sh names the base the upstream-tracking branch has:
    # built before a push, an image reports the previous base
    # (jeeves/HANDOFF-x3000-rebuild.md). Both the sysupgrade metadata and
    # base-files' /etc/openwrt_release must name this tree.
    want_rev="$(cd "$root" && ./scripts/getver.sh)"
    fwtool="$(feed_hostbin fwtool)"
    meta="$(feed_mktemp)"
    "$fwtool" -q -i "$meta" "$bin" 2>/dev/null \
        || feed_die "$bin has no fwtool metadata (was staging_dir/host/bin/fwtool missing at build time?)"
    rev="$(jq -r '.version.revision // ""' "$meta")"
    [[ "$rev" == "$want_rev" ]] || feed_die "image revision '$rev' is not this tree's '$want_rev'"
    got="$(feed_rootfs_cat "$sqfs" etc/openwrt_release)"
    grep -qxF "DISTRIB_REVISION='$want_rev'" <<< "$got" \
        || feed_die "image /etc/openwrt_release is not revision $want_rev (stale base-files?):"$'\n'"$got"
    rm -f "$sqfs" "$meta"
}

feed_manifest_kernel() {
    local manifest="$1" kver
    [[ -f "$manifest" ]] || feed_die "missing manifest $manifest"
    kver="$(awk '$1 == "kernel" && $2 == "-" { print $3 }' "$manifest")"
    if [[ -z "$kver" || "$kver" == *$'\n'* ]]; then
        feed_die "$manifest: expected exactly one 'kernel - <version>' line"
    fi
    printf '%s\n' "$kver"
}

# Step 4: pkgdir holds one kernel package, for kver, and every kmod in it
# depends on exactly kernel=kver. Outputs are clean in release mode, so a
# mismatch is a real problem: stop, never filter.
feed_check_kmods() {
    local pkgdir="$1" kver="$2" work tsv kernels bad
    compgen -G "$pkgdir/kmod-*.apk" >/dev/null || feed_die "no kmod-*.apk in $pkgdir (is CONFIG_ALL_KMODS=y in effect?)"
    compgen -G "$pkgdir/kernel-*.apk" >/dev/null || feed_die "no kernel-*.apk in $pkgdir"
    work="$(feed_mktemp -d)"
    ( cd "$pkgdir" && feed_apk mkndx --allow-untrusted --output "$work/check.adb" kmod-*.apk kernel-*.apk >/dev/null ) \
        || feed_die "cannot index the kmods in $pkgdir"
    tsv="$(feed_index_tsv "$work/check.adb")"
    rm -rf "$work"
    kernels="$(awk -F'\t' '$1 == "kernel" { print $2 }' <<< "$tsv")"
    [[ "$kernels" == "$kver" ]] || feed_die "$pkgdir holds kernel package(s) '$kernels', manifest says '$kver'"
    bad="$(awk -F'\t' -v want="kernel=$kver" '
        $1 ~ /^kmod-/ {
            n = split($4, d, " "); ok = 0; foreign = 0
            for (i = 1; i <= n; i++) {
                if (d[i] == want) ok = 1
                else if (d[i] ~ /^kernel[=<>~]/) foreign = 1
            }
            if (!ok || foreign) print "  " $1 "-" $2 " (depends: " $4 ")"
        }' <<< "$tsv")"
    [[ -z "$bad" ]] || feed_die "kmods not built for kernel=$kver:"$'\n'"$bad"
}

# The kernel version kmods/<tag>/ is published for, or nothing.
feed_published_kernel() {
    local adb="$1/kmods/$2/packages.adb" tsv
    [[ -f "$adb" ]] || return 0
    tsv="$(feed_index_tsv "$adb")"
    awk -F'\t' '$1 == "kernel" { print $2 }' <<< "$tsv"
}

# Refresh guard: a tag's kmods are for one kernel, forever.
feed_check_refresh() {
    local stage="$1" tag="$2" kver="$3" published
    published="$(feed_published_kernel "$stage" "$tag")"
    if [[ -n "$published" && "$published" != "$kver" ]]; then
        feed_die "kmods/$tag/ is published for kernel $published, this build has $kver: kernel changed → cut a new tag"
    fi
}
