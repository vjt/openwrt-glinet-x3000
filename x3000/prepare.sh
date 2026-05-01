#!/usr/bin/env bash
#
# x3000/prepare.sh — set up the OpenWrt build tree to produce a GL-X3000
# image. Two variants are supported:
#
#   private  bad.ass fleet image — telegraf-full pushing to
#            metrics.bad.ass, internal CA, signed-feed pubkey.
#            (Default; preserves the historical behaviour.)
#
#   public   no bad.ass extras — same hardware enablement (modem stack,
#            quectel-5g-tools, adb, LuCI bundle) but no internal CA,
#            no internal feed key, no telegraf push.
#
# Usage:  x3000/prepare.sh [private|public]
#
# What it does, idempotently:
#   1. Clones the custom package repos listed in x3000/custom-feeds.txt
#      into .build-deps/ (gitignored). Each repo is fetched + checked out
#      to the pinned ref on every run.
#   2. Creates symlinks under feeds-local/ pointing at the package
#      subdirectory inside each clone. `feeds-local/` is what
#      /feeds.conf's `src-link custom` references.
#   3. Copies x3000/feeds.conf -> /feeds.conf so OpenWrt's `feeds update`
#      sees the standard 25.12 feeds plus our custom symlinks.
#   4. Composes /.config from x3000/config.common + x3000/config.<variant>
#      and runs `make defconfig` to expand it into a full config tree.
#   5. Wipes /files/ and rebuilds it from x3000/files-common/ +
#      x3000/files-<variant>/, so swapping variants leaves no stale
#      overlay files behind.
#   6. Records the active variant in /.x3000-variant for build.sh and
#      sanity checks.
#   7. Runs `./scripts/feeds update -a && ./scripts/feeds install -a` so
#      every Makefile is symlinked into package/feeds/.
#   8. Applies x3000/patches/*.patch against feed-side files (modemmanager
#      tty hotplug etc.).

set -euo pipefail

VARIANT="${1:-private}"
case "$VARIANT" in
    private|public) ;;
    *)
        echo "usage: $0 [private|public]" >&2
        echo "  unknown variant: $VARIANT" >&2
        exit 2
        ;;
esac

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DEPS="$ROOT/.build-deps"
LOCAL="$ROOT/feeds-local"
FEEDS_LIST="$ROOT/x3000/custom-feeds.txt"
FEEDS_CONF_SRC="$ROOT/x3000/feeds.conf"
CONFIG_COMMON="$ROOT/x3000/config.common"
CONFIG_VARIANT="$ROOT/x3000/config.$VARIANT"
FILES_COMMON="$ROOT/x3000/files-common"
FILES_VARIANT="$ROOT/x3000/files-$VARIANT"
VARIANT_MARKER="$ROOT/.x3000-variant"

echo "==> Preparing X3000 build tree (variant=$VARIANT)"

mkdir -p "$DEPS" "$LOCAL"

if [[ ! -f "$FEEDS_LIST" ]]; then
    echo "missing $FEEDS_LIST" >&2
    exit 1
fi
for f in "$CONFIG_COMMON" "$CONFIG_VARIANT"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 1; }
done
for d in "$FILES_COMMON" "$FILES_VARIANT"; do
    [[ -d "$d" ]] || { echo "missing $d" >&2; exit 1; }
done

# --- Clone / refresh custom repos and link them into feeds-local/ ---------

echo "==> Refreshing custom package repos"

while IFS= read -r raw_line; do
    line="${raw_line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    [[ -z "$line" ]] && continue

    read -r name url ref subdir <<< "$line"
    [[ -z "${subdir:-}" ]] && {
        echo "malformed line in $FEEDS_LIST: $raw_line" >&2
        exit 1
    }

    # Derive a stable directory name from the URL so multiple feeds backed
    # by the same repo (e.g. android-tools + brotli, both inside
    # openwrt-android-tools.git) share a single clone.
    repo_basename="$(basename "${url%.git}")"
    clone_dir="$DEPS/$repo_basename"

    if [[ ! -d "$clone_dir/.git" ]]; then
        echo "  cloning $url -> $clone_dir"
        git clone "$url" "$clone_dir"
    fi

    git -C "$clone_dir" fetch --quiet origin
    git -C "$clone_dir" -c advice.detachedHead=false checkout --quiet "$ref"
    # If $ref is a branch, fast-forward; if it's a SHA the pull is a no-op.
    if git -C "$clone_dir" rev-parse --verify --quiet "refs/remotes/origin/$ref" >/dev/null; then
        git -C "$clone_dir" reset --hard --quiet "origin/$ref"
    fi

    src_dir="$clone_dir/$subdir"
    if [[ ! -d "$src_dir" ]]; then
        echo "  $repo_basename has no subdir '$subdir' (looking for $src_dir)" >&2
        exit 1
    fi

    link="$LOCAL/$name"
    if [[ -L "$link" || -e "$link" ]]; then
        rm -f "$link"
    fi
    ln -s "$src_dir" "$link"
    echo "  feeds-local/$name -> $src_dir"
done < "$FEEDS_LIST"

# --- Drop the build-host feeds.conf in place ------------------------------

echo "==> Installing feeds.conf"
# scripts/feeds resolves `src-link` paths against an internal CWD that is
# not the SDK root, so a relative `feeds-local` here ends up pointing at
# the wrong place and the index comes out empty. Substitute the absolute
# path to feeds-local under the current build root before installing.
sed "s|^src-link custom feeds-local\$|src-link custom $LOCAL|" \
    "$FEEDS_CONF_SRC" > "$ROOT/feeds.conf"

# --- Compose .config from common + variant --------------------------------

echo "==> Composing .config from config.common + config.$VARIANT"
{
    cat "$CONFIG_COMMON"
    echo
    echo "# --- variant: $VARIANT ---"
    cat "$CONFIG_VARIANT"
} > "$ROOT/.config"
make defconfig FORCE=1 >/dev/null

# --- Compose files/ overlay from files-common + files-<variant> ----------

echo "==> Composing files/ from files-common + files-$VARIANT"
# Wipe first so leftovers from a previous variant can't sneak in.
rm -rf "$ROOT/files"
mkdir -p "$ROOT/files"
# rsync --exclude='.gitkeep' keeps git-bookkeeping out of the composed
# rootfs at copy time — no copy-then-delete dance. -a preserves modes
# (uci-defaults scripts must stay executable).
rsync -a --exclude='.gitkeep' "$FILES_COMMON"/ "$ROOT/files/"
rsync -a --exclude='.gitkeep' "$FILES_VARIANT"/ "$ROOT/files/"

# --- Record the variant ---------------------------------------------------

echo "$VARIANT" > "$VARIANT_MARKER"

# --- feeds update + install -----------------------------------------------

# `./scripts/feeds update -a` does `git pull --rebase` inside each feed
# checkout. If we patched a feed file on a previous run (see the patch
# loop further down), the rebase blocks on those unstaged changes — so
# reset every feed back to its tracked HEAD first. The patches are
# re-applied below from x3000/patches/, so this round-trip is safe.
for feeddir in "$ROOT"/feeds/*; do
    [[ -d "$feeddir/.git" ]] || continue
    git -C "$feeddir" checkout --quiet -- . 2>/dev/null || true
done

echo "==> feeds update -a"
./scripts/feeds update -a

echo "==> feeds install -a"
./scripts/feeds install -a

# --- Apply unified-diff patches against feed contents ---------------------
#
# OpenWrt's quilt-based patch system applies to upstream package SOURCES,
# not to the OpenWrt-side `files/` overlays each package ships. We
# nonetheless need to tweak one such file (modemmanager's tty hotplug,
# see x3000/patches/0001-modemmanager-tty-honour-ignore-tty.patch for
# the why), so we apply our patches here against the relevant feed paths.
#
# Idempotent: if a patch is already applied (e.g. re-running prepare.sh
# without `feeds update -a` having happened in between), we detect that
# via a reverse dry-run and skip silently. If neither forward nor reverse
# applies cleanly the script bails out — that's the loud signal that
# upstream has drifted and the patch needs refreshing.
PATCH_DIR="$ROOT/x3000/patches"
if [[ -d "$PATCH_DIR" ]]; then
    for patchfile in "$PATCH_DIR"/*.patch; do
        [[ -f "$patchfile" ]] || continue
        name="$(basename "$patchfile")"
        # -F 0 disables fuzzy matching: any context drift is a hard fail,
        # which is the whole point of using a unified diff over a files/
        # overlay — we want to know the moment upstream changes the file
        # we patch.
        if patch --reverse --dry-run --silent -F 0 -p1 < "$patchfile" >/dev/null 2>&1; then
            echo "==> patch already applied: $name"
            continue
        fi
        echo "==> applying patch: $name"
        if ! patch --forward -r - -F 0 -p1 < "$patchfile"; then
            echo "FATAL: $name did not apply cleanly. Upstream feed has likely" >&2
            echo "drifted; refresh the patch against the new upstream file." >&2
            exit 1
        fi
    done
fi

echo
echo "Done. variant=$VARIANT"
echo "Run 'make -j\$(nproc)' (add V=s for verbose output)"
echo "or 'x3000/build.sh $VARIANT' to also relocate artifacts to bin-x3000-$VARIANT/."
