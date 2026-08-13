#!/bin/sh
set -eu

integration_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
checkout=$(CDPATH='' cd -- "$integration_root/../../.." && pwd)
work_root=$(mktemp -d "${TMPDIR:-/tmp}/android-workbench-adapters.XXXXXX")
trap 'rm -rf "$work_root"' EXIT HUP INT TERM

resolve_plugin() {
  name=$1
  candidate=$2
  source_url=$3
  revision=$4
  resolved_plugin=

  if [ -d "$candidate/.git" ] &&
    [ "$(git -C "$candidate" rev-parse HEAD)" = "$revision" ] &&
    [ -z "$(git -C "$candidate" status --porcelain)" ]; then
    resolved_plugin=$candidate
    return
  fi

  resolved_plugin="$work_root/$name"
  git init -q "$resolved_plugin"
  git -C "$resolved_plugin" fetch -q --depth 1 "$source_url" "$revision"
  git -C "$resolved_plugin" checkout -q --detach FETCH_HEAD
  if [ "$(git -C "$resolved_plugin" rev-parse HEAD)" != "$revision" ]; then
    echo "$name did not resolve the pinned revision." >&2
    exit 1
  fi
}

resolve_plugin \
  telescope \
  "${AWB_TELESCOPE_PATH:-$HOME/.local/share/nvim/site/pack/core/opt/telescope.nvim}" \
  https://github.com/nvim-telescope/telescope.nvim.git \
  427b576c16792edad01a92b89721d923c19ad60f
telescope_path=$resolved_plugin

resolve_plugin \
  snacks \
  "${AWB_SNACKS_PATH:-$HOME/.local/share/nvim/site/pack/core/opt/snacks.nvim}" \
  https://github.com/folke/snacks.nvim.git \
  882c996cf28183f4d63640de0b4c02ec886d01f2
snacks_path=$resolved_plugin

resolve_plugin \
  plenary \
  "${AWB_PLENARY_PATH:-$HOME/.local/share/nvim/site/pack/core/opt/plenary.nvim}" \
  https://github.com/nvim-lua/plenary.nvim.git \
  74b06c6c75e4eeb3108ec01852001636d85a932b
plenary_path=$resolved_plugin

resolve_plugin \
  overseer \
  "${AWB_OVERSEER_PATH:-$HOME/.local/share/nvim/site/pack/core/opt/overseer.nvim}" \
  https://github.com/stevearc/overseer.nvim.git \
  a93d9f6d6defdac4bcd6d2c8ba988650e42e0a0e
overseer_path=$resolved_plugin

xdg_root="$work_root/xdg"
mkdir -p "$xdg_root/config" "$xdg_root/data" "$xdg_root/state" "$xdg_root/cache"

env \
  ANDROID_WORKBENCH_TEST_ROOT="$checkout" \
  AWB_OVERSEER_PATH="$overseer_path" \
  AWB_PLENARY_PATH="$plenary_path" \
  AWB_SNACKS_PATH="$snacks_path" \
  AWB_TELESCOPE_PATH="$telescope_path" \
  NVIM_APPNAME=android-workbench-integration \
  XDG_CACHE_HOME="$xdg_root/cache" \
  XDG_CONFIG_HOME="$xdg_root/config" \
  XDG_DATA_HOME="$xdg_root/data" \
  XDG_STATE_HOME="$xdg_root/state" \
  nvim --headless -u "$checkout/tests/minimal_init.lua" -i NONE \
    "+luafile $integration_root/verify.lua"
