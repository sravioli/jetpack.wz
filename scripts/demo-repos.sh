#!/usr/bin/env bash
# Build the git repositories the screenshots install, so nothing touches the
# network or the plugins on this machine.
#
#   scripts/demo-repos.sh init DIR   old releases only
#   scripts/demo-repos.sh bump DIR   newer releases, so a check finds updates
#
# DIR/<name>.wz is one repository per plugin.
set -euo pipefail

mode=${1:?usage: demo-repos.sh init|bump DIR}
dir=${2:?usage: demo-repos.sh init|bump DIR}

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null # no signing prompts from your own git config
export GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@example.com
export GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@example.com

commit() { # repo message [tag]
  # jetpack treats a clone as installed only when it has plugin/init.lua.
  mkdir -p "$dir/$1.wz/plugin"
  echo "return {}" >"$dir/$1.wz/plugin/init.lua"
  echo "$2" >>"$dir/$1.wz/CHANGES"
  git -C "$dir/$1.wz" add -A
  git -C "$dir/$1.wz" commit -q -m "$2"
  [ -z "${3:-}" ] || git -C "$dir/$1.wz" tag "$3"
}

case "$mode" in
  init)
    for name in beacon chord lantern mosaic ribbon; do
      git init -q -b main "$dir/$name.wz"
    done
    commit beacon "feat: check for new releases" 1.0.0
    commit chord "feat: key notation" 2.0.0
    commit lantern "feat: font selector"
    commit mosaic "feat: status bar" 3.0.0
    commit ribbon "feat: styled text" 1.4.0
    commit ribbon "fix: width of wide glyphs" 1.4.2
    ;;
  bump)
    commit beacon "fix: skip toasts while a window is busy"
    commit beacon "feat: add a stable channel" 1.1.0
    commit chord "fix: leader timeout in key tables"
    commit chord "feat: grouped help overlay" 2.1.0
    commit lantern "feat: cursor style selector"
    commit lantern "fix: restore the saved font size"
    commit mosaic "feat: new slanted preset" # a tag pin ignores it
    commit ribbon "feat: gradients" 1.5.0 # outside ~1.4
    ;;
  *) echo "unknown mode: $mode" >&2; exit 1 ;;
esac
