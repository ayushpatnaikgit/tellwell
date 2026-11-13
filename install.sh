#!/bin/sh
# One-line installer for TellWell: private dictation that runs on your Mac.
#
#   curl -fsSL https://raw.githubusercontent.com/ayushpatnaikgit/tellwell/main/install.sh | sh
#
# Installs (or updates) TellWell from its latest GitHub release, after checking the release's SHA-256 and the app's
# identifier; installs the freeflow-local engine (speech recognition on the Neural Engine and a fine-tuned cleanup
# model, all on your Mac); and points TellWell at it. It does this by running freeflow-local's installer with
# --app tellwell, so options after `sh -s --` are passed through, for example:
#   curl -fsSL .../install.sh | sh -s -- --no-autostart
# Needs an Apple Silicon Mac on macOS 14 or later (the engine's requirement).
set -eu

GET="${FREEFLOW_LOCAL_GET:-https://raw.githubusercontent.com/ayushpatnaikgit/freeflow-local/main/get.sh}"
tmp=$(mktemp "${TMPDIR:-/tmp}/tellwell-get.XXXXXX")
trap 'rm -f "$tmp"' EXIT INT TERM
curl -fsSL "$GET" -o "$tmp" || { echo "Error: could not download the installer from $GET" >&2; exit 1; }
sh "$tmp" --app tellwell "$@"
