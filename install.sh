#!/bin/bash
# Registers this checkout as the Omarchy shell plugin "eca".
#
# Modes:
#   ./install.sh            symlink the checkout directory into the plugins folder
#                           (best for development — edits are live, no copy step)
#   ./install.sh --copy     copy files instead (explicit, or fallback)
#   ./install.sh --link     force (re)create the symlink even if one already exists
#
# What it does:
#   1. Symlink or copy the plugin files into ~/.config/omarchy/plugins/eca
#   2. Validate with `omarchy plugin validate`
#   3. Hot-reload the running shell with `omarchy-shell shell rescanPlugins`
#   4. Enable the bar widget (right side) if not already registered in shell.json
#
# The preferred install path for end-users (no checkout needed) is:
#   omarchy plugin add https://github.com/<user>/omarchy-eca.git --enable
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/eca"
plugins_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"

# ── argument parsing ─────────────────────────────────────────────────────────
mode="auto"   # auto | link | copy
for arg in "$@"; do
  case "$arg" in
    --link) mode="link" ;;
    --copy) mode="copy" ;;
    *)      echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ── helpers ──────────────────────────────────────────────────────────────────

is_our_symlink() {
  # True when $dest is a symlink that resolves to $src.
  [[ -L "$dest" ]] && [[ "$(readlink -f "$dest")" == "$src" ]]
}

is_enabled() {
  # True when "eca" already appears in shell.json (either in plugins[] or
  # bar.layout.*[]).  If shell.json is absent, treat as not enabled.
  local shell_json="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
  [[ -f "$shell_json" ]] || return 1
  python3 -c "
import json, sys
d = json.load(open('$shell_json'))
# Check plugins list (services / overlays / panels)
for p in d.get('plugins', []):
    if p.get('id') == 'eca':
        sys.exit(0)
# Check bar layout sections
for section in d.get('bar', {}).get('layout', {}).values():
    for w in section:
        if w.get('id') == 'eca':
            sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

bb_ok() {
  [[ -x "$src/bin/bb" ]] || command -v bb >/dev/null 2>&1
}

warn_if_no_bb() {
  if ! bb_ok; then
    echo "warning: babashka (bb) not found and bin/bb not present." >&2
    echo "         Install bb (https://babashka.org) or push a release tag to" >&2
    echo "         trigger the CI workflow that populates bin/bb." >&2
    echo "         The plugin will not function until one of these is available." >&2
  fi
}

do_symlink() {
  # Remove whatever is currently at $dest (real dir, old symlink, anything)
  # and replace it with a symlink to the checkout.
  if is_our_symlink; then
    echo "Already symlinked: $dest -> $src"
    return 0
  fi
  rm -rf "$dest"
  ln -s "$src" "$dest"
  echo "Symlinked: $dest -> $src"
}

validate_path() {
  # The omarchy validator uses `find "$PLUGIN_DIR" -type l` which includes the
  # starting path itself when it is a symlink — so we always validate the real
  # (resolved) path, not the symlink entry in the plugins folder.
  omarchy plugin validate "$(readlink -f "$dest")"
}

do_copy() {
  # Full file copy — no symlink, safe for deployment / git-based install.
  mkdir -p "$dest/bin"
  for f in manifest.json Service.qml Session.qml Panel.qml \
            ChatView.qml ChatWindow.qml \
            eca_bridge.bb eca_workspaces.bb README.md bb.edn; do
    [[ -f "$src/$f" ]] && install -m 0644 "$src/$f" "$dest/$f"
  done
  for f in test/run_tests.bb test/eca_workspaces_test.bb test/eca_bridge_test.bb; do
    if [[ -f "$src/$f" ]]; then
      mkdir -p "$dest/test"
      install -m 0644 "$src/$f" "$dest/$f"
    fi
  done
  chmod +x "$dest"/*.bb
  if [[ -x "$src/bin/bb" ]]; then
    install -m 0755 "$src/bin/bb" "$dest/bin/bb"
    echo "Copied bin/bb"
  fi
  echo "Copied files to: $dest"
}

# ── main ─────────────────────────────────────────────────────────────────────

warn_if_no_bb
mkdir -p "$plugins_dir"

case "$mode" in
  auto)
    # Try symlink first; fall back to copy only if validate rejects the real path.
    do_symlink
    if ! validate_path 2>/dev/null; then
      echo "Checkout failed validation — falling back to file copy..." >&2
      rm "$dest"
      do_copy
    fi
    ;;
  link)
    do_symlink
    ;;
  copy)
    # Remove a symlink if present so we get a real directory.
    [[ -L "$dest" ]] && rm "$dest"
    do_copy
    ;;
esac

# Always validate the real resolved path (not the symlink entry itself).
validate_path

# Hot-reload the running shell.
omarchy-shell shell rescanPlugins >/dev/null 2>&1 && echo "Shell rescanned." || true

# Enable only if not already registered — avoids creating duplicate entries.
if is_enabled; then
  echo "Plugin already enabled — skipping enable step."
else
  omarchy plugin enable eca right
  echo "Plugin enabled on the right of the bar."
fi

echo "Done. Plugin is at: $dest"
if is_our_symlink; then
  echo "Mode: symlink (edits in $src are live immediately)"
else
  echo "Mode: copy (run ./install.sh --copy to push new changes)"
fi
