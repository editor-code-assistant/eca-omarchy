#!/usr/bin/env bash
# Bootstrap script for the omarchy-eca plugin.
#
# The plugin manages its own runtime dependencies — bb (Babashka) and the
# eca server — as part of normal operation.  This script runs on every shell
# start, ensuring both are present and the plugin can start working
# immediately.  It is idempotent: when both binaries already exist it
# completes in under 100 ms without any network access.
#
# Requires only: bash, curl, unzip, tar  (all standard on Arch/Omarchy).
#
# Streams one JSON line per step to stdout so the QML UI shows live progress:
#
#   {"step":"checking"}
#   {"step":"downloading","what":"bb","message":"Downloading Babashka…"}
#   {"step":"downloading","what":"eca","message":"Downloading ECA 0.161.2…"}
#   {"step":"done","bb":"/home/…/.local/bin/bb",
#    "eca":"/home/…/.local/bin/eca","ecaVersion":"0.161.2"}
#   {"step":"error","message":"…"}
#
# Also appends to ~/.cache/omarchy-eca/setup.log.
set -euo pipefail

INSTALL_DIR="$HOME/.local/bin"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-eca"
LOG="$CACHE_DIR/setup.log"
TMP_DIR="$CACHE_DIR/setup-tmp"

mkdir -p "$INSTALL_DIR" "$CACHE_DIR"

# ── JSON helpers (pure bash — no python/jq required) ────────────────────────

json_str() {
  local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"
  printf '%s' "\"$s\""
}

emit() {
  printf '%s\n' "$1"
  printf '[%s] %s\n' "$(date -Iseconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG"
}

emit_step() {     # emit_step key val key val …
  local json="{\"step\":$(json_str "$1")"; shift
  while [[ $# -ge 2 ]]; do json+=",$(json_str "$1"):$(json_str "$2")"; shift 2; done
  emit "${json}}"
}

die() {
  local MJ; MJ=$(json_str "$*")
  emit "{\"step\":\"error\",\"message\":${MJ}}"
  printf '[%s] ERROR: %s\n' "$(date -Iseconds 2>/dev/null || date -u)" "$*" >> "$LOG"
  exit 1
}

log() { printf '[%s] %s\n' "$(date -Iseconds 2>/dev/null || date -u)" "$*" >> "$LOG"; }

# ── Platform ─────────────────────────────────────────────────────────────────

ARCH=$(uname -m)

bb_platform()  {
  case "$ARCH" in
    x86_64)  echo "linux-amd64-static" ;;
    aarch64) echo "linux-aarch64-static" ;;
    *)       die "Unsupported architecture: $ARCH" ;;
  esac
}

eca_platform() {
  case "$ARCH" in
    x86_64)  echo "static-linux-amd64" ;;
    aarch64) echo "linux-aarch64" ;;
    *)       die "Unsupported architecture: $ARCH" ;;
  esac
}

# ── Download helper ──────────────────────────────────────────────────────────

fetch_json() {   # fetch_json URL → prints response body
  curl -fsSL --connect-timeout 15 --max-time 30 "$1" 2>>"$LOG"
}

latest_tag() {   # latest_tag owner/repo → tag name
  fetch_json "https://api.github.com/repos/$1/releases/latest" \
    | grep '"tag_name"' | sed 's/.*"\([^"]*\)".*/\1/'
}

download() {     # download URL dest
  log "GET $1"
  curl -fL --silent --show-error --connect-timeout 30 --max-time 300 \
       --output "$2" "$1" 2>>"$LOG" || die "Download failed: $1"
  [[ -s "$2" ]] || die "Empty download: $1"
}

# ── Version helper ───────────────────────────────────────────────────────────

get_version() { "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }

# ── Find existing binaries ───────────────────────────────────────────────────

find_bb() {
  for f in "$INSTALL_DIR/bb" "$HOME/.local/bin/bb"; do
    [[ -x "$f" ]] && { echo "$f"; return; }
  done
  command -v bb 2>/dev/null || true
}

find_eca() {
  for f in "$INSTALL_DIR/eca" \
            "$HOME/.local/bin/eca" \
            "$HOME/.emacs.d/eca/eca" \
            "$HOME/.config/emacs/eca/eca" \
            "$HOME/em/eca/eca" \
            "$HOME/.local/share/nvim/eca/eca" \
            "$HOME/.cache/eca/bin/eca"; do
    [[ -x "$f" ]] && { echo "$f"; return; }
  done
  command -v eca 2>/dev/null || true
}

# ── Install bb ───────────────────────────────────────────────────────────────

install_bb() {
  local version platform archive url
  version=$(latest_tag "babashka/babashka") || die "Could not fetch latest Babashka release"
  version="${version#v}"   # strip leading v if present
  [[ -n "$version" ]] || die "Could not determine Babashka version"
  platform=$(bb_platform)
  archive="babashka-${version}-${platform}.tar.gz"
  url="https://github.com/babashka/babashka/releases/download/v${version}/${archive}"

  emit_step "downloading" \
    "what"    "bb" \
    "version" "$version" \
    "message" "Downloading Babashka ${version}…"

  mkdir -p "$TMP_DIR"
  download "$url" "$TMP_DIR/bb.tar.gz"

  # Verify checksum when available
  local sha
  sha=$(fetch_json "${url}.sha256" 2>/dev/null | awk '{print $1}' || true)
  if [[ -n "$sha" ]]; then
    echo "$sha  $TMP_DIR/bb.tar.gz" | sha256sum --check --quiet 2>>"$LOG" \
      || die "Babashka checksum mismatch — download may be corrupted"
  fi

  tar -xzf "$TMP_DIR/bb.tar.gz" -C "$TMP_DIR" bb
  "$TMP_DIR/bb" --version >>"$LOG" 2>&1 || die "Downloaded bb failed smoke test"
  mv "$TMP_DIR/bb" "$INSTALL_DIR/bb"
  rm -rf "$TMP_DIR"
  log "Installed bb $version → $INSTALL_DIR/bb"
}

# ── Install eca ──────────────────────────────────────────────────────────────

install_eca() {
  local version platform url
  version=$(latest_tag "editor-code-assistant/eca") || die "Could not fetch latest eca release"
  [[ -n "$version" ]] || die "Could not determine eca version"
  platform=$(eca_platform)
  url="https://github.com/editor-code-assistant/eca/releases/download/${version}/eca-native-${platform}.zip"

  emit_step "downloading" \
    "what"    "eca" \
    "version" "$version" \
    "message" "Downloading ECA ${version}…"

  mkdir -p "$TMP_DIR"
  download "$url" "$TMP_DIR/eca.zip"

  # Verify digest before extraction and execution — eca releases publish
  # a companion .sha256 file for every zip asset.
  local sha_url="${url}.sha256"
  local expected_sha
  expected_sha=$(fetch_json "$sha_url" 2>/dev/null | awk '{print $1}' || true)
  if [[ -n "$expected_sha" ]]; then
    echo "$expected_sha  $TMP_DIR/eca.zip" | sha256sum --check --quiet 2>>"$LOG" \
      || die "eca checksum mismatch — download may be corrupted or tampered"
    log "eca sha256 verified: $expected_sha"
  else
    die "Could not fetch eca checksum from $sha_url — refusing to execute unverified binary"
  fi

  unzip -qq -o "$TMP_DIR/eca.zip" -d "$TMP_DIR/eca-extract" 2>>"$LOG" \
    || die "Could not extract eca zip"

  local extracted
  extracted=$(find "$TMP_DIR/eca-extract" -name "eca" -type f | head -1)
  [[ -n "$extracted" ]] || die "eca binary not found in downloaded zip"

  # Atomic install: write to .new, verify, rename
  cp "$extracted" "$INSTALL_DIR/eca.new"
  chmod +x "$INSTALL_DIR/eca.new"
  "$INSTALL_DIR/eca.new" --version >>"$LOG" 2>&1 || die "Downloaded eca binary failed smoke test"
  mv "$INSTALL_DIR/eca.new" "$INSTALL_DIR/eca"
  rm -rf "$TMP_DIR"
  log "Installed eca $version → $INSTALL_DIR/eca"
}

# ── Main ─────────────────────────────────────────────────────────────────────

log "=== eca_setup.sh starting (arch=$ARCH) ==="
emit_step "checking"

BB=$(find_bb)
if [[ -z "$BB" ]]; then
  install_bb
  BB="$INSTALL_DIR/bb"
else
  log "bb: $BB ($(get_version "$BB"))"
fi

ECA=$(find_eca)
if [[ -z "$ECA" ]]; then
  install_eca
  ECA="$INSTALL_DIR/eca"
else
  log "eca: $ECA ($(get_version "$ECA"))"
fi

ECA_VERSION=$(get_version "$ECA")

BB_J=$(json_str "$BB"); ECA_J=$(json_str "$ECA"); VER_J=$(json_str "$ECA_VERSION")
emit "{\"step\":\"done\",\"bb\":${BB_J},\"eca\":${ECA_J},\"ecaVersion\":${VER_J}}"
log "=== done: bb=$BB eca=$ECA ($ECA_VERSION) ==="
