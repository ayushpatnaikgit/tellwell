#!/bin/sh
# One-line installer for TellWell: private dictation that runs on your Mac.
#
#   curl -fsSL https://ayushpatnaikgit.github.io/tellwell/install.sh | sh
#
# Installs (or updates) TellWell from its latest GitHub release, after checking the disk image's SHA-256 and that
# the app is signed with TellWell's certificate, then opens it. TellWell downloads its speech and cleanup models
# itself on first launch (about 830 MB, once); nothing else is installed.
# Needs an Apple Silicon Mac on macOS 14 or later (the speech models need it).
set -eu

BASE="${TELLWELL_RELEASE:-https://github.com/ayushpatnaikgit/tellwell/releases/latest/download}"
# The app's designated requirement: its identifier and the certificate its releases are signed with.
REQUIREMENT='identifier "io.github.ayushpatnaikgit.tellwell" and certificate leaf = H"f37d1a1521d7e1871ed0cdee2009d5636da9abd2"'

say() { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "TellWell runs on macOS only."
[ "$(uname -m)" = arm64 ] || fail "TellWell needs an Apple Silicon Mac (M1 or later)."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "TellWell needs macOS 14 (Sonoma) or later."

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tellwell.XXXXXX")
MOUNT="$WORK/mnt"
cleanup() {
  if [ -d "$MOUNT" ]; then hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; fi
  rm -rf "${WORK:?}"
}
trap cleanup EXIT INT TERM

say "Downloading TellWell from github.com/ayushpatnaikgit/tellwell..."
curl -fsSL "$BASE/TellWell.dmg" -o "$WORK/TellWell.dmg" || fail "could not download TellWell.dmg"
curl -fsSL "$BASE/TellWell.dmg.sha256" -o "$WORK/TellWell.dmg.sha256" || fail "could not download its checksum"
expected=$(cut -d' ' -f1 "$WORK/TellWell.dmg.sha256")
actual=$(shasum -a 256 "$WORK/TellWell.dmg" | cut -d' ' -f1)
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "checksum mismatch for TellWell.dmg; not installing it."

mkdir -p "$MOUNT"
hdiutil attach -nobrowse -readonly -noautoopen -quiet -mountpoint "$MOUNT" "$WORK/TellWell.dmg" \
  || fail "could not open the TellWell disk image."
app="$MOUNT/TellWell.app"
[ -d "$app" ] || fail "the TellWell disk image does not contain TellWell.app."
codesign --verify --deep --strict -R="$REQUIREMENT" "$app" 2>/dev/null \
  || fail "TellWell.app is not signed with TellWell's certificate; not installing it."

if [ -w /Applications ]; then dest=/Applications; else dest="$HOME/Applications"; fi
mkdir -p "$dest"
osascript -e 'quit app id "io.github.ayushpatnaikgit.tellwell"' 2>/dev/null || true
rm -rf "$dest/TellWell.app"
ditto "$app" "$dest/TellWell.app" || fail "could not copy TellWell to $dest."
say "TellWell installed in $dest. Opening it: it will download its models once (about 830 MB)."
open "$dest/TellWell.app"
