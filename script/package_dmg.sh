#!/usr/bin/env bash
set -euo pipefail

# Build a signed app bundle first, then put that verified bundle into a simple
# drag-to-Applications disk image.  The app remains signed with the stable
# local identity used by build_and_run.sh; this script does not invent a second
# signing path for the DMG itself.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="HedgeMemo"
VERSION="1.1.0"
DIST_DIR="$ROOT_DIR/dist"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
STAGING_DIR="/private/tmp/hedgememo-dmg-$$"
INSTALLED_APP="$HOME/Applications/$APP_NAME.app"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/script/build_and_run.sh" --verify

if [[ ! -d "$INSTALLED_APP" ]]; then
  echo "Expected signed app bundle at $INSTALLED_APP" >&2
  exit 1
fi

# The project lives in a File Provider-backed Documents folder, which may
# reattach Finder metadata to a copied `dist/*.app` at any time. Package from
# the verified installation copy outside Documents instead; build_and_run.sh
# has already completed strict verification for this exact bundle.
codesign --verify --deep --strict "$INSTALLED_APP"
mkdir -p "$STAGING_DIR"
/usr/bin/ditto --noextattr --noqtn "$INSTALLED_APP" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"

/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Created $DMG_PATH"
