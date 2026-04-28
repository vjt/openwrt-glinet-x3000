#!/usr/bin/env bash
#
# x3000/prepare.sh — set up the OpenWrt build tree to produce a GL-X3000
# image with the bad.ass fleet baseline.
#
# What it does, idempotently:
#   1. Clones the custom package repos listed in x3000/custom-feeds.txt
#      into .build-deps/ (gitignored). Each repo is fetched + checked out
#      to the pinned ref on every run, so changing the ref + re-running
#      reflects the new state without you having to clean up.
#   2. Creates symlinks under feeds-local/ pointing at the package
#      subdirectory inside each clone (e.g. .build-deps/<repo>/openwrt/<pkg>).
#      `feeds-local/` is what /feeds.conf's `src-link custom` references.
#   3. Copies x3000/feeds.conf -> /feeds.conf so OpenWrt's `feeds update`
#      sees the standard 25.12 feeds plus our custom symlinks.
#   4. Copies .config-x3000 -> /.config and runs `make defconfig` to
#      expand it into a full config tree.
#   5. Runs `./scripts/feeds update -a && ./scripts/feeds install -a` so
#      every Makefile is symlinked into package/feeds/.
#
# After it finishes you can `make -j$(nproc)` (or `V=s` for verbose) and
# the artifacts land under bin/targets/mediatek/filogic/.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DEPS="$ROOT/.build-deps"
LOCAL="$ROOT/feeds-local"
FEEDS_LIST="$ROOT/x3000/custom-feeds.txt"
FEEDS_CONF_SRC="$ROOT/x3000/feeds.conf"
CONFIG_OVERLAY="$ROOT/.config-x3000"

mkdir -p "$DEPS" "$LOCAL"

if [[ ! -f "$FEEDS_LIST" ]]; then
    echo "missing $FEEDS_LIST" >&2
    exit 1
fi

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
cp -f "$FEEDS_CONF_SRC" "$ROOT/feeds.conf"

# --- Apply the X3000 config overlay ---------------------------------------

echo "==> Applying $CONFIG_OVERLAY -> .config"
cp -f "$CONFIG_OVERLAY" "$ROOT/.config"
make defconfig FORCE=1 >/dev/null

# --- feeds update + install -----------------------------------------------

echo "==> feeds update -a"
./scripts/feeds update -a

echo "==> feeds install -a"
./scripts/feeds install -a

echo
echo "Done. Run 'make -j\$(nproc)' (add V=s for verbose output)."
echo "Artifacts will land under bin/targets/mediatek/filogic/."
