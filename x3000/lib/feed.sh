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

# A public release build must be reproducible from the pushed commit, but
# prepare.sh also reads these gitignored per-builder files for the public
# variant. Called by prepare.sh before it touches anything; coreutils only.
feed_check_public_overlays() {
    local root="$1" f
    for f in x3000/config.public.local x3000/custom-feeds.public.local; do
        if [[ -e "$root/$f" ]]; then
            feed_die "$root/$f would change the public release image but is not in the pushed commit: move it away for the release build"
        fi
    done
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
    # A published index that names no kernel (or several) proves nothing:
    # passing would let a changed kernel be published under these kmods.
    if [[ -f "$stage/kmods/$tag/packages.adb" ]]; then
        if [[ -z "$published" ]]; then
            feed_die "kmods/$tag/packages.adb lists no kernel package: cannot check the refresh"
        elif [[ "$published" == *$'\n'* ]]; then
            feed_die "kmods/$tag/packages.adb lists several kernel packages: cannot check the refresh"
        fi
    fi
    if [[ -n "$published" && "$published" != "$kver" ]]; then
        feed_die "kmods/$tag/ is published for kernel $published, this build has $kver: kernel changed → cut a new tag"
    fi
}

# Published names are immutable: a file already in gh-pages keeps its
# bytes, so a stale index cached anywhere between us and a device still
# resolves to the bytes it hashed. A rebuild with an unchanged version is
# therefore not republished: ship a change with a version bump.
feed_stage_file() {
    local src="$1" destdir="$2" name
    name="$(basename "$src")"
    if [[ -e "$destdir/$name" ]]; then
        if ! cmp -s "$src" "$destdir/$name"; then
            feed_log "kept published $name (same name, different bytes: bump the version to ship a change)"
        fi
        return 0
    fi
    cp "$src" "$destdir/$name"
}

# The .apk files in srcdir whose origin is a public custom feed (origins:
# one per line, from feed_custom_origins). bin/packages/<arch>/custom/ is
# shared with the private variant, so anything else — a package from
# custom-feeds.private.local — is left out. A listed origin that produced
# nothing means an incomplete build.
feed_select_custom() {
    local srcdir="$1" origins="$2" apk tsv origin seen=""
    compgen -G "$srcdir/*.apk" >/dev/null || feed_die "no .apk in $srcdir"
    for apk in "$srcdir"/*.apk; do
        tsv="$(feed_pkg_tsv "$apk")"
        origin="$(cut -f3 <<< "$tsv")"
        if grep -qxF -- "$origin" <<< "$origins"; then
            printf '%s\n' "$apk"
            seen+="$origin"$'\n'
        else
            feed_log "excluded $(basename "$apk") (origin $origin is not in custom-feeds.txt)"
        fi
    done
    while read -r origin; do
        [[ -n "$origin" ]] || continue
        if ! grep -qxF -- "$origin" <<< "$seen"; then
            feed_die "no package built from $origin (listed in custom-feeds.txt)"
        fi
    done <<< "$origins"
}

feed_stage_kmods() {
    local stage="$1" tag="$2" pkgdir="$3" f
    mkdir -p "$stage/kmods/$tag"
    for f in "$pkgdir"/kmod-*.apk "$pkgdir"/kernel-*.apk; do
        feed_stage_file "$f" "$stage/kmods/$tag"
    done
}

feed_stage_custom() {
    local stage="$1" srcdir="$2" origins="$3" selected f
    selected="$(feed_select_custom "$srcdir" "$origins")"
    mkdir -p "$stage/custom"
    while read -r f; do
        [[ -n "$f" ]] || continue
        feed_stage_file "$f" "$stage/custom"
    done <<< "$selected"
}

# TAGS lists the published kmods tags, newest first. A tag not yet listed
# becomes the newest; the newest FEED_KEEP_TAGS stay, and kmods/ dirs of
# any other tag are dropped. Images older than the retained tags get a
# 404 on kmods: a loud failure.
feed_update_tags() {
    local stage="$1" tag="$2" tags="" d
    if [[ -f "$stage/TAGS" ]]; then
        tags="$(cat "$stage/TAGS")"
    fi
    if ! grep -qxF -- "$tag" <<< "$tags"; then
        tags="$tag"$'\n'"$tags"
    fi
    tags="$(awk -v keep="$FEED_KEEP_TAGS" 'NF && n < keep { print; n++ }' <<< "$tags")"
    printf '%s\n' "$tags" > "$stage/TAGS"
    for d in "$stage"/kmods/*/; do
        [[ -d "$d" ]] || continue
        d="$(basename "$d")"
        if ! grep -qxF -- "$d" <<< "$tags"; then
            feed_log "retention: dropping kmods/$d/"
            rm -rf "${stage:?}/kmods/$d"
        fi
    done
}

# Versions on stdin, newest first on stdout, in apk's own ordering
# (1.10.10 > 1.9.0, which a lexical sort gets backwards).
feed_version_sort_desc() {
    local -a sorted=()
    local v i cmp
    while read -r v; do
        [[ -n "$v" ]] || continue
        i=0
        # The comparison runs in the body, not the while condition, where
        # set -e is suspended: a failing apk must die, not misplace v and
        # make feed_prune_custom delete the newest package.
        while (( i < ${#sorted[@]} )); do
            cmp="$(feed_apk version -t "${sorted[i]}" "$v")" || cmp=""
            case "$cmp" in
                '>') i=$((i + 1)) ;;
                '<'|'=') break ;;
                *) feed_die "cannot compare versions '${sorted[i]}' and '$v' (apk version -t said '$cmp')" ;;
            esac
        done
        sorted=("${sorted[@]:0:i}" "$v" "${sorted[@]:i}")
    done
    if (( ${#sorted[@]} )); then
        printf '%s\n' "${sorted[@]}"
    fi
}

# Keeps the newest FEED_KEEP_VERSIONS versions of each custom package.
feed_prune_custom() {
    local dir="$1/custom" f tsv lines="" names name versions version n
    for f in "$dir"/*.apk; do
        [[ -e "$f" ]] || continue
        tsv="$(feed_pkg_tsv "$f")"
        lines+="$(cut -f1,2 <<< "$tsv")"$'\t'"$f"$'\n'
    done
    names="$(awk -F'\t' 'NF { print $1 }' <<< "$lines" | sort -u)"
    while read -r name; do
        [[ -n "$name" ]] || continue
        versions="$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' <<< "$lines" | feed_version_sort_desc)"
        n=0
        while read -r version; do
            n=$((n + 1))
            if (( n <= FEED_KEEP_VERSIONS )); then
                continue
            fi
            f="$(awk -F'\t' -v n="$name" -v v="$version" '$1 == n && $2 == v { print $3 }' <<< "$lines")"
            feed_log "retention: dropping custom/$(basename "$f")"
            rm -f "$f"
        done <<< "$versions"
    done <<< "$names"
}

# gh-pages holds exactly the feed layout: anything else (the Pages spike's
# spike/ and spike-bad/, strays) goes.
feed_prune_unknown() {
    local stage="$1" e name
    for e in "$stage"/* "$stage"/.[!.]*; do
        [[ -e "$e" ]] || continue
        name="$(basename "$e")"
        case "$name" in
            .git|.nojekyll|TAGS|kmods|custom) ;;
            *)
                feed_log "removing $name from gh-pages (not part of the feed layout)"
                rm -rf "$e"
                ;;
        esac
    done
}

# Step 5 for a release: kmods/<tag>/ and custom/ over the current gh-pages
# tree, retention applied, both indexes re-signed and verified.
feed_stage_release() {
    local stage="$1" tag="$2" pkgdir="$3" customsrc="$4" origins="$5" root="$6"
    feed_prune_unknown "$stage"
    touch "$stage/.nojekyll"
    feed_stage_kmods "$stage" "$tag" "$pkgdir"
    feed_update_tags "$stage" "$tag"
    feed_stage_custom "$stage" "$customsrc" "$origins"
    feed_prune_custom "$stage"
    feed_reindex "$stage/kmods/$tag" "$root"
    feed_reindex "$stage/custom" "$root"
}

# publish-feed.sh: custom/ only; kmods/ and TAGS stay as published.
feed_stage_custom_only() {
    local stage="$1" customsrc="$2" origins="$3" root="$4"
    feed_prune_unknown "$stage"
    touch "$stage/.nojekyll"
    feed_stage_custom "$stage" "$customsrc" "$origins"
    feed_prune_custom "$stage"
    feed_reindex "$stage/custom" "$root"
}

# Clones gh-pages (depth 1) into dest and prints the commit it starts
# from — publish leases on it — or nothing when the branch does not
# exist yet (dest is then an empty repo with origin set).
feed_clone_pages() {
    local dest="$1" heads
    heads="$(git ls-remote --heads "$FEED_GIT_URL" gh-pages)" || feed_die "cannot reach $FEED_GIT_URL"
    if [[ -z "$heads" ]]; then
        git init -q "$dest"
        git -C "$dest" remote add origin "$FEED_GIT_URL"
        return 0
    fi
    git clone -q --depth 1 --single-branch --branch gh-pages "$FEED_GIT_URL" "$dest" \
        || feed_die "cannot clone gh-pages of $FEED_GIT_URL"
    git -C "$dest" rev-parse HEAD
}

# Continuity guard: the published custom/ index must verify with our
# local public key, or the key changed and every device would reject
# what we are about to sign. Skipped only when custom/packages.adb is
# not in the gh-pages git tree (nothing published yet) — never because
# a fetch failed.
feed_continuity_check() {
    local clone="$1" root="$2" base="${3:-$FEED_BASE_URL}" listed tmp
    if ! git -C "$clone" rev-parse -q --verify HEAD >/dev/null; then
        feed_log "continuity: gh-pages does not exist yet, skipping"
        return 0
    fi
    listed="$(git -C "$clone" ls-tree --name-only HEAD -- custom/packages.adb)"
    if [[ -z "$listed" ]]; then
        feed_log "continuity: nothing published under custom/ yet, skipping"
        return 0
    fi
    tmp="$(feed_mktemp)"
    curl -fsS --retry 3 -o "$tmp" "$base/custom/packages.adb" \
        || feed_die "continuity: custom/packages.adb is in gh-pages but $base/custom/packages.adb cannot be fetched"
    feed_verify_index "$tmp" "$root/public-key.pem"
    rm -f "$tmp"
    feed_log "continuity: the published custom/ index verifies with $root/public-key.pem"
}

# Commits the staged tree as a fresh orphan (history never accumulates;
# unchanged blobs are not re-uploaded) and force-pushes gh-pages, leased
# on the commit we cloned so a concurrent publish is refused. Prints the
# pushed commit.
feed_publish() {
    local clone="$1" base="$2" msg="$3"
    git -C "$clone" checkout -q --orphan feed-publish
    git -C "$clone" add -A
    git -C "$clone" commit -q -m "$msg"
    git -C "$clone" push -q --force-with-lease="gh-pages:$base" origin HEAD:refs/heads/gh-pages \
        || feed_die "push to $FEED_GIT_URL gh-pages failed (did someone publish meanwhile?)"
    git -C "$clone" rev-parse HEAD
}

# Pages takes ~30 s from push to served; errored is fatal.
feed_wait_pages_build() {
    local commit="$1" deadline json built status
    deadline=$((SECONDS + FEED_TIMEOUT))
    while (( SECONDS < deadline )); do
        if json="$(gh api "repos/$FEED_GH_REPO/pages/builds/latest" 2>/dev/null)"; then
            built="$(jq -r '.commit // ""' <<< "$json")"
            status="$(jq -r '.status // ""' <<< "$json")"
            if [[ "$built" == "$commit" ]]; then
                case "$status" in
                    built)
                        feed_log "Pages built $commit"
                        return 0
                        ;;
                    errored)
                        feed_die "Pages build of $commit errored: $(jq -r '.error.message // ""' <<< "$json")"
                        ;;
                esac
            fi
        fi
        sleep "$FEED_POLL_INTERVAL"
    done
    feed_die "Pages did not build $commit within ${FEED_TIMEOUT}s"
}

# Polls base/<relpath> until it serves the bytes staged in stage/<relpath>.
feed_wait_served() {
    local base="$1" stage="$2" rel want got tmp deadline
    shift 2
    tmp="$(feed_mktemp)"
    deadline=$((SECONDS + FEED_TIMEOUT))
    for rel in "$@"; do
        want="$(sha256sum < "$stage/$rel" | cut -d' ' -f1)"
        while :; do
            got=""
            if curl -fsS -o "$tmp" "$base/$rel" 2>/dev/null; then
                got="$(sha256sum < "$tmp" | cut -d' ' -f1)"
            fi
            if [[ "$got" == "$want" ]]; then
                break
            fi
            (( SECONDS < deadline )) || feed_die "$base/$rel does not serve the published bytes after ${FEED_TIMEOUT}s"
            sleep "$FEED_POLL_INTERVAL"
        done
        feed_log "served: $rel"
    done
    rm -f "$tmp"
}

# Serves dir on an ephemeral 127.0.0.1 port. Sets FEED_SERVE_PID and
# FEED_SERVE_URL; the caller kills FEED_SERVE_PID. Call as a plain
# statement: in $(…) the variables would be lost.
feed_serve() {
    local dir="$1" log port="" i
    log="$(feed_mktemp)"
    python3 -u -m http.server --bind 127.0.0.1 --directory "$dir" 0 > "$log" 2>&1 &
    FEED_SERVE_PID=$!
    for i in $(seq 100); do
        port="$(sed -n 's/.* port \([0-9]*\) .*/\1/p' "$log")"
        if [[ -n "$port" ]]; then
            break
        fi
        sleep 0.1
    done
    [[ -n "$port" ]] || feed_die "local http server did not start: $(cat "$log")"
    FEED_SERVE_URL="http://127.0.0.1:$port"
}

# Predicate: 0 if a GitHub release exists for the tag, 1 if not; dies
# if GitHub cannot tell (never treat "unknown" as "absent").
feed_release_exists() {
    local out
    if out="$(gh api "repos/$RELEASE_GH_REPO/releases/tags/$1" 2>&1)"; then
        return 0
    fi
    if grep -q 'HTTP 404' <<< "$out"; then
        return 1
    fi
    feed_die "cannot query release $1 on $RELEASE_GH_REPO: $out"
}

# A tag missing from TAGS becomes the newest one. That is only right for
# a tag without a GitHub release yet: an already-released tag outside
# TAGS predates the feed or fell out of retention.
feed_check_new_tag() {
    local stage="$1" tag="$2"
    if [[ -f "$stage/TAGS" ]] && grep -qxF -- "$tag" "$stage/TAGS"; then
        return 0
    fi
    if feed_release_exists "$tag"; then
        feed_die "$tag is already released but not in the feed's TAGS: cut a new tag"
    fi
}

# apk add --simulate in a canary root: a non-zero rc or any UNTRUSTED
# index (apk only warns, then carries on without it) is fatal; must,
# when given, has to appear in the output.
feed_canary_resolve() {
    local root="$1" must="$2" out rc=0
    shift 2
    out="$(feed_apk --root "$root" --usermode add --simulate "$@" 2>&1)" || rc=$?
    if (( rc != 0 )) || grep -qi untrusted <<< "$out"; then
        feed_die "canary: apk add --simulate $* failed (rc=$rc):"$'\n'"$out"
    fi
    if [[ -n "$must" ]] && ! grep -qF -- "$must" <<< "$out"; then
        feed_die "canary: expected '$must' resolving $*:"$'\n'"$out"
    fi
    feed_log "canary: $* resolves"
}

# The #7 canary, from a scratch root that sees exactly what a device
# running the image sees: its keys, its upstream feeds and our two feed
# lines (rewritten to base when checking a staged tree on localhost).
# kmod-wireguard + wireguard-tools must resolve with kernel = kver, and
# every package in custom/ must resolve, which proves their
# dependencies are satisfiable on this image.
feed_canary() {
    local bin="$1" base="$2" kver="$3" work unsq root names init_out list line has_custom=0 has_kmods=0
    local -a pkgs
    work="$(feed_mktemp -d)"
    feed_extract_rootfs "$bin" "$work/root.sqfs"
    unsq="$(feed_hostbin unsquashfs4)"
    "$unsq" -no-xattrs -d "$work/img" "$work/root.sqfs" etc/apk >/dev/null 2>&1 \
        || feed_die "canary: cannot extract /etc/apk from $bin"
    root="$work/root"
    mkdir -p "$root/etc/apk"
    cp -a "$work/img/etc/apk/arch" "$work/img/etc/apk/keys" "$work/img/etc/apk/repositories.d" "$root/etc/apk/" \
        || feed_die "canary: the image's /etc/apk lacks arch, keys or repositories.d"
    [[ -f "$root/etc/apk/repositories.d/$FEED_LIST_NAME" ]] || feed_die "canary: image has no $FEED_LIST_NAME"
    if [[ "$base" != "$FEED_BASE_URL" ]]; then
        sed -i "s|^$FEED_BASE_URL/|$base/|" "$root/etc/apk/repositories.d/$FEED_LIST_NAME"
    fi
    # The rewrite matches nothing when the image lists another base, and
    # the canary would then resolve against whatever the image names (the
    # live feed, say) and pass: require both lines to be under base.
    list="$(cat "$root/etc/apk/repositories.d/$FEED_LIST_NAME")"
    while IFS= read -r line; do
        if [[ "$line" == "$base/custom/packages.adb" ]]; then
            has_custom=1
        elif [[ "$line" == "$base/kmods/"?*"/packages.adb" ]]; then
            has_kmods=1
        fi
    done <<< "$list"
    if (( ! has_custom || ! has_kmods )); then
        feed_die "canary: the image's $FEED_LIST_NAME does not point at $base:"$'\n'"$list"
    fi
    # initdb is what fetches the indexes (apk 3.0.5), so an UNTRUSTED one
    # is reported here; add --simulate later only says "no such package".
    init_out="$(feed_apk --root "$root" --usermode add --initdb 2>&1)" \
        || feed_die "canary: cannot initialise $root:"$'\n'"$init_out"
    if grep -qi untrusted <<< "$init_out"; then
        feed_die "canary: the image's feeds include an UNTRUSTED index (apk add --initdb):"$'\n'"$init_out"
    fi

    feed_canary_resolve "$root" "Installing kernel ($kver)" kmod-wireguard wireguard-tools

    curl -fsS -o "$work/custom.adb" "$base/custom/packages.adb" \
        || feed_die "canary: cannot fetch $base/custom/packages.adb"
    names="$(feed_index_tsv "$work/custom.adb")"
    names="$(cut -f1 <<< "$names" | sort -u)"
    [[ -n "$names" ]] || feed_die "canary: $base/custom/packages.adb lists no package"
    mapfile -t pkgs <<< "$names"
    feed_canary_resolve "$root" "" "${pkgs[@]}"
    rm -rf "$work"
}

# Tree guard: build from committed, pushed code. scripts/getver.sh
# derives the image version from the upstream-tracking branch, so an
# unpushed tree yields an image that lies about its version.
feed_check_tree() {
    local root="$1" strict="$2" problem="" head upstream dirty
    head="$(git -C "$root" rev-parse HEAD)"
    upstream="$(git -C "$root" rev-parse -q --verify '@{upstream}' 2>/dev/null || true)"
    # Untracked files count: prepare.sh applies an untracked patch or
    # overlay file all the same, and the release record would name a
    # commit that lacks it. A plain statement, so a git failure is not
    # read as "clean".
    dirty="$(git -C "$root" status --porcelain)"
    if [[ -n "$dirty" ]]; then
        problem="tracked files have uncommitted changes or the tree has untracked files"
    elif [[ "$head" != "$upstream" ]]; then
        problem="HEAD is not pushed to its upstream branch (the image would report the wrong version)"
    fi
    if [[ -z "$problem" ]]; then
        return 0
    fi
    if (( strict )); then
        feed_die "$problem"
    fi
    feed_warn "$problem (dry run: continuing)"
}

# The release assets, all from bin-x3000-public/ and nowhere else.
feed_release_files() {
    printf '%s\n' \
        "$1/$FEED_IMAGE_PREFIX-squashfs-sysupgrade.bin" \
        "$1/$FEED_IMAGE_PREFIX.manifest" \
        "$1/$FEED_IMAGE_PREFIX-preloader.bin" \
        "$1/$FEED_IMAGE_PREFIX-bl31-uboot.fip" \
        "$1/SHA256SUMS"
}

feed_write_sums() {
    local bindir="$1"
    ( cd "$bindir" && sha256sum \
          "$FEED_IMAGE_PREFIX-squashfs-sysupgrade.bin" \
          "$FEED_IMAGE_PREFIX-preloader.bin" \
          "$FEED_IMAGE_PREFIX-bl31-uboot.fip" \
          "$FEED_IMAGE_PREFIX.manifest" > SHA256SUMS ) \
        || feed_die "cannot checksum the artifacts in $bindir"
}

# What `feed` verified, for `upload` to check: the commit the tag goes
# on, and the hash of every asset.
feed_write_record() {
    local bindir="$1" tag="$2" commit="$3" files f
    files="$(feed_release_files "$bindir")"
    {
        printf 'commit %s\n' "$commit"
        while read -r f; do
            ( cd "$bindir" && sha256sum "$(basename "$f")" )
        done <<< "$files"
    } > "$bindir/.release-$tag"
}

feed_check_record() {
    local bindir="$1" tag="$2" record="$1/.release-$2" commit
    [[ -f "$record" ]] || feed_die "no $record: run 'release.sh feed $tag' first (upload only ships what feed verified)"
    commit="$(awk '$1 == "commit" { print $2 }' "$record")"
    [[ -n "$commit" ]] || feed_die "$record has no commit line"
    [[ "$(grep -vc '^commit ' "$record")" == 5 ]] || feed_die "$record does not list the 5 release assets"
    ( cd "$bindir" && grep -v '^commit ' "$record" | sha256sum --check --strict --quiet ) \
        || feed_die "artifacts in $bindir changed since 'release.sh feed $tag'"
    printf '%s\n' "$commit"
}
# Downloads the released image and manifest for tag, checked against the
# release's own SHA256SUMS: devices run the released image, not a fresh
# build, so that is what publish-feed.sh's canary uses.
feed_fetch_release() {
    local tag="$1" dest="$2" f
    mkdir -p "$dest"
    gh release download "$tag" -R "$RELEASE_GH_REPO" -D "$dest" \
            -p "$FEED_IMAGE_PREFIX-squashfs-sysupgrade.bin" \
            -p "$FEED_IMAGE_PREFIX.manifest" \
            -p SHA256SUMS >/dev/null 2>&1 \
        || feed_die "cannot download release $tag from $RELEASE_GH_REPO"
    for f in "$FEED_IMAGE_PREFIX-squashfs-sysupgrade.bin" "$FEED_IMAGE_PREFIX.manifest"; do
        [[ -f "$dest/$f" ]] || feed_die "release $tag has no $f"
        grep -q "  $f\$" "$dest/SHA256SUMS" || feed_die "release $tag's SHA256SUMS does not list $f"
    done
    ( cd "$dest" && sha256sum --check --ignore-missing --quiet SHA256SUMS ) >/dev/null 2>&1 \
        || feed_die "release $tag assets do not match its SHA256SUMS"
}
