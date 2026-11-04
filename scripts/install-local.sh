#!/usr/bin/env bash
# Build this checkout with `make local` and install it to /Applications/VoiceInk.app.
#
# Signs with a stable Apple Development identity so macOS keeps Microphone, Accessibility
# and Screen Recording permissions across rebuilds. Ad-hoc builds change identity every
# time and must be re-granted. The identity comes from LOCAL_CODESIGN_IDENTITY, else
# ~/.config/voiceink/signing-identity (a SHA-1 hash or full name from
# `security find-identity -v -p codesigning`).
#
# Usage: scripts/install-local.sh [--skip-build]
#   --skip-build  install the existing .local-build product without rebuilding
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="VoiceInk"
BUILT_APP=".local-build/Build/Products/Release/${APP_NAME}.app"
INSTALLED_APP="/Applications/${APP_NAME}.app"
BACKUP_DIR="${HOME}/Library/Application Support/VoiceInk/Backups"
KEEP_BACKUPS=3
IDENTITY_FILE="${HOME}/.config/voiceink/signing-identity"

skip_build=false
for arg in "$@"; do
	case "$arg" in
		--skip-build) skip_build=true ;;
		*) echo "Unknown option: $arg" >&2; exit 2 ;;
	esac
done

identity="${LOCAL_CODESIGN_IDENTITY:-}"
if [ -z "$identity" ] && [ -f "$IDENTITY_FILE" ]; then
	identity="$(tr -d '[:space:]' < "$IDENTITY_FILE")"
fi
if [ -z "$identity" ]; then
	echo "No signing identity: set LOCAL_CODESIGN_IDENTITY or write one to $IDENTITY_FILE." >&2
	echo "Without one, every rebuild needs permissions re-granted." >&2
	exit 1
fi

if [ "$skip_build" = false ]; then
	make local LOCAL_CODESIGN_IDENTITY="$identity"
fi
[ -d "$BUILT_APP" ] || { echo "No built app at $BUILT_APP" >&2; exit 1; }
codesign --verify --deep --strict "$BUILT_APP"

if pgrep -x "$APP_NAME" >/dev/null; then
	osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
	for _ in $(seq 1 40); do
		pgrep -x "$APP_NAME" >/dev/null || break
		sleep 0.25
	done
	if pgrep -x "$APP_NAME" >/dev/null; then
		echo "${APP_NAME} did not quit; close it and rerun." >&2
		exit 1
	fi
fi

if [ -d "$INSTALLED_APP" ]; then
	mkdir -p "$BACKUP_DIR"
	backup="${BACKUP_DIR}/${APP_NAME}-app-$(date +%Y%m%d-%H%M%S).app"
	ditto "$INSTALLED_APP" "$backup"
	echo "Backed up current app to: $backup"
	# Keep only the newest app backups; other files in the folder are left alone.
	find "$BACKUP_DIR" -maxdepth 1 -name "${APP_NAME}-app-*.app" -type d | sort -r \
		| tail -n +"$((KEEP_BACKUPS + 1))" | while IFS= read -r old; do rm -rf "$old"; done
	rm -rf "$INSTALLED_APP"
fi

ditto "$BUILT_APP" "$INSTALLED_APP"
xattr -cr "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"
open "$INSTALLED_APP"
echo "Installed $(git rev-parse --abbrev-ref HEAD)@$(git rev-parse --short HEAD) to $INSTALLED_APP"
