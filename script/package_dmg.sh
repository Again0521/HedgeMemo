#!/usr/bin/env bash
set -euo pipefail

# Build a signed app bundle first, then put that verified bundle into a simple
# drag-to-Applications disk image.  The app remains signed with the stable
# local identity used by build_and_run.sh; this script does not invent a second
# signing path for the DMG itself.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="HedgeMemo"
VERSION="1.2.5"
DIST_DIR="$ROOT_DIR/dist"
DIST_APP="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
STAGING_DIR="/private/tmp/hedgememo-dmg-$$"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/script/build_and_run.sh" --package

if [[ ! -d "$DIST_APP" ]]; then
  echo "Expected signed app bundle at $DIST_APP" >&2
  exit 1
fi

# The project lives in a File Provider-backed Documents folder, which may
# reattach Finder metadata to `dist/*.app` at any time. Copy without extended
# attributes into a private staging directory and verify the exact staged
# bundle before creating the image.
mkdir -p "$STAGING_DIR"
/usr/bin/ditto --noextattr --noqtn "$DIST_APP" "$STAGING_DIR/$APP_NAME.app"
# File Provider may race the copy and materialize Finder/resource-fork
# metadata inside the loose dist bundle before `ditto` reads it. The private
# staging copy is outside Documents, so one recursive cleanup here is stable
# and does not require re-signing or any administrator access.
xattr -cr "$STAGING_DIR/$APP_NAME.app"
codesign --verify --deep --strict "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"

# `hdiutil create` is deprecated in favour of `diskutil image create`, but that
# subcommand only exists on newer systems. Prefer it when present so the build
# is warning-free, and keep hdiutil for older build machines. Both produce the
# same UDZO (compressed, read-only) image.
if /usr/sbin/diskutil image create from --help >/dev/null 2>&1; then
  /usr/sbin/diskutil image create from \
    --format UDZO \
    --volumeName "$APP_NAME" \
    "$STAGING_DIR" \
    "$DMG_PATH"
else
  /usr/bin/hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
fi

# `dist` lives under a File Provider-backed Documents checkout. The provider
# can reattach Finder metadata to a loose app bundle seconds after it was
# signed, making that intermediate artifact fail strict verification even
# though the clean staged bundle inside the completed DMG is valid. Keep the
# release artifact only; `build_and_run.sh --package` remains available when a
# standalone app bundle is explicitly needed.
rm -rf "$DIST_APP"

echo "Created $DMG_PATH"
