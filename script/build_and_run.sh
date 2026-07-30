#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="HedgeMemo"
BUNDLE_ID="com.hedgememo.app"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
DIST_APP="$DIST_DIR/$APP_NAME.app"
# Assemble and sign outside the cloud-backed Documents checkout. File Provider
# can attach Finder metadata to a bundle between xattr cleanup and codesign,
# making an otherwise valid build fail strict verification nondeterministically.
PACKAGE_DIR="/private/tmp/hedgememo-package-$$"
APP_BUNDLE="$PACKAGE_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

# Keep the runnable bundle outside the source checkout. Together with the
# pasteboard policy this ensures routine startup never touches Documents.
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
rm -rf "$PACKAGE_DIR"
trap 'rm -rf "$PACKAGE_DIR"' EXIT

cd "$ROOT_DIR"
# Install a production binary. Shipping the debug executable leaves absolute
# DWARF source paths pointing back into the repository under Documents; macOS
# may resolve those paths while validating/symbolicating each newly signed app,
# which produces a fresh Documents-folder prompt after every rebuild.
swift build -c release --product "$APP_NAME"
BUILD_DIR="$(swift build -c release --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
LOCALIZATION_BUNDLE="$BUILD_DIR/HedgeMemo_HedgeMemoCore.bundle"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp -X "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
strip -x "$APP_BINARY"

if [[ ! -d "$LOCALIZATION_BUNDLE" ]]; then
  echo "Missing localization bundle at $LOCALIZATION_BUNDLE" >&2
  exit 1
fi
/usr/bin/ditto --noextattr --noqtn "$LOCALIZATION_BUNDLE" "$APP_RESOURCES/$(basename "$LOCALIZATION_BUNDLE")"

cp -X "$ROOT_DIR/Sources/HedgeMemo/Resources/Hedgehog.png" "$APP_RESOURCES/Hedgehog.png"
cp -X "$ROOT_DIR/Sources/HedgeMemo/Resources/Hedgehog.svg" "$APP_RESOURCES/Hedgehog.svg"

# First-run sample memes. Each sample may be supplied in any common image
# format; copy whichever extension is present. A missing sample is simply
# skipped at seeding time.
for meme_index in 1 2 3; do
  for meme_ext in png jpg jpeg gif; do
    meme_src="$ROOT_DIR/Sources/HedgeMemo/Resources/DefaultMeme${meme_index}.${meme_ext}"
    if [[ -f "$meme_src" ]]; then
      cp -X "$meme_src" "$APP_RESOURCES/DefaultMeme${meme_index}.${meme_ext}"
      break
    fi
  done
done

if [[ -f "$ROOT_DIR/Assets/AppIcon.icns" ]]; then
  cp -X "$ROOT_DIR/Assets/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key>
<array>
<string>en</string>
<string>zh-Hans</string>
</array>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.2.31</string>
<key>CFBundleVersion</key><string>1.2.31</string>
<key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
<key>LSUIElement</key><true/>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<!-- LocalAuthentication renders its Touch ID prompt through an out-of-process
     view that reads these from the host bundle. A bundle missing them made the
     remote view throw from containingWindowWillOrderOnScreen:, aborting the
     app the moment a window carrying that view was ordered on screen. -->
<key>NSFaceIDUsageDescription</key><string>HedgeMemo uses Touch ID to unlock protected clipboard categories.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSEnvironment</key>
<dict>
<!-- macOS 26/27's Swift 6 concurrency runtime crashes in
     swift_task_isCurrentExecutorImpl (a dynamic MainActor-isolation probe that
     dereferences a stale executor) during ordinary SwiftUI ForEach body
     updates. "legacy" restores the pre-Swift-6, non-crashing executor check —
     Apple's supported migration escape hatch for exactly this runtime bug. -->
<key>SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE</key><string>legacy</string>
</dict>
</dict></plist>
PLIST

# Cloud-backed Documents folders attach Finder/file-provider metadata to newly
# assembled bundles. Remove that packaging detritus before signing, then fail
# the build if the installed application cannot be verified.
xattr -cr "$APP_BUNDLE"
# A stable identity is required: an ad-hoc fallback changes the cdhash every
# build and makes macOS regard the update as a new screen-recording client.
SIGN_IDENTITY="HedgeMemo Local Signing"
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE"
else
  echo "Missing stable signing identity '$SIGN_IDENTITY'. Run ./script/setup_signing.sh once before packaging." >&2
  exit 1
fi
# The File Provider may reattach root metadata as soon as signing mutates the
# bundle. Those attributes are not app content and must be removed once more
# before strict verification.
xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
xattr -d com.apple.fileprovider.fpfs#P "$APP_BUNDLE" 2>/dev/null || true
codesign --verify --deep --strict "$APP_BUNDLE"

# Export the conventional dist artifact directly from the verified temporary
# bundle. Package mode stops here: it never installs or launches the app, so it
# is safe for unattended builds and cannot trigger an administrator prompt.
mkdir -p "$DIST_DIR"
rm -rf "$DIST_APP"
/usr/bin/ditto --noextattr --noqtn "$APP_BUNDLE" "$DIST_APP"
# Finder/File Provider can attach metadata to nested resource bundles as well
# as the app root while `ditto` is still walking the tree. It can also race the
# cleanup itself, so couple cleanup and verification in a bounded retry loop.
# Extended attributes are not signed app content.
dist_verified=false
for _ in 1 2 3 4 5; do
  xattr -cr "$DIST_APP"
  if codesign --verify --deep --strict "$DIST_APP"; then
    dist_verified=true
    break
  fi
done
if [[ "$dist_verified" != true ]]; then
  echo "Unable to verify $DIST_APP after removing File Provider metadata" >&2
  exit 1
fi

if [[ "$MODE" == "--package" || "$MODE" == "package" ]]; then
  echo "Prepared $DIST_APP without installing or launching it"
  exit 0
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
/usr/bin/ditto --noextattr --noqtn "$DIST_APP" "$INSTALLED_APP"
xattr -d com.apple.FinderInfo "$INSTALLED_APP" 2>/dev/null || true
xattr -d com.apple.fileprovider.fpfs#P "$INSTALLED_APP" 2>/dev/null || true
codesign --verify --deep --strict "$INSTALLED_APP"

open_app() {
  # LaunchServices should not inherit the repository's Documents working
  # directory. On sandbox-aware macOS releases that inheritance can be
  # mistaken for an app request to access Documents after each rebuilt bundle.
  (
    cd /private/tmp
    /usr/bin/open -n "$INSTALLED_APP"
  )
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$INSTALLED_APP/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--package]" >&2
    exit 2
    ;;
esac
