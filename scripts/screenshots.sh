#!/usr/bin/env bash
# Screenshot the jetpack picker, a plugin's menu, the changes view, the results
# view and the mosaic.wz bar modules, dark (kanagawa-wave) and light
# (kanagawa-lotus) from the kanagawa plugin
# (https://github.com/kanagawa-community/wezterm): .github/assets/<scene>/{dark,light}.png.
#
# Needs KDE Plasma (spectacle), wezterm, git and ImageMagick; oxipng is used when
# installed. The scenes install demo plugins from throwaway git repositories, so
# the network and your own plugins stay untouched. Needs sibling checkouts of
# warp.wz, warden.wz and mosaic.wz next to this repository.
# Run it from a session you leave alone: each shot opens a window that must
# keep the focus until it is captured.
#
#   scripts/screenshots.sh                  # every scene
#   scripts/screenshots.sh picker results   # only these
#
# Scenes: picker plugin changes results bar
#
# Settings (environment): JETPACK_FONT ("FiraCode Nerd Font"), JETPACK_FONT_SIZE (14),
# JETPACK_COLS (100), JETPACK_ROWS (30), JETPACK_DELAY (seconds to wait for the window, default 8).
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
delay=${JETPACK_DELAY:-8}
all=(picker plugin changes results bar)
scenes=("${@:-${all[@]}}")

for tool in wezterm spectacle git magick; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done
for name in warp warden mosaic; do
  [ -d "$repo/../$name.wz/plugin" ] || { echo "missing sibling checkout: ../$name.wz" >&2; exit 1; }
done

export JETPACK_REPO="$repo"
JETPACK_DEMO=$(mktemp -d)
export JETPACK_DEMO
trap 'rm -rf "$JETPACK_DEMO"' EXIT

shoot() { # scene kanagawa-scheme file-name
  local dir="$repo/.github/assets/$1"
  mkdir -p "$dir"
  # A fresh set of repositories, clones and lockfile for every shot.
  rm -rf "${JETPACK_DEMO:?}"/*
  mkdir -p "$JETPACK_DEMO/repos"
  "$repo/scripts/demo-repos.sh" init "$JETPACK_DEMO/repos"
  JETPACK_SCENE=$1 JETPACK_KANAGAWA=$2 \
    wezterm --config-file "$repo/scripts/screenshot.wezterm.lua" start --always-new-process &
  local pid=$!
  sleep "$delay"
  spectacle --activewindow --background --nonotify --output "$dir/$3.png"
  case "$1" in
    bar) magick "$dir/$3.png" -gravity North -crop 100%x50%+0+0 +repage "$dir/$3.png" ;;
  esac
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  command -v oxipng >/dev/null && oxipng -q -o4 --strip all "$dir/$3.png"
  echo "$dir/$3.png"
}

for scene in "${scenes[@]}"; do
  shoot "$scene" wave dark
  shoot "$scene" lotus light
done
