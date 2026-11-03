#!/bin/zsh
# Builds build/hdlanes.app (release) from the SwiftPM products.
#
#   scripts/build-app.sh            build and sign build/hdlanes.app
#   scripts/build-app.sh --install  also replace /Applications/hdlanes.app
#   scripts/build-app.sh --zip      also make build/hdlanes-<version>.zip
#
# Signs with the first "Apple Development" identity in the keychain, otherwise ad-hoc.
# HDLANES_SIGN_IDENTITY overrides the choice ("-" forces ad-hoc).
set -e
set -o pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

INSTALL=0
ZIP=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --zip) ZIP=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

PLIST_SRC="$ROOT/Resources/Info.plist"
ICON_SRC="$ROOT/Resources/hdlanes.icns"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_SRC")"

echo "==> swift build -c release (hdlanes, hdlanes-hook)"
swift build -c release --product hdlanes
swift build -c release --product hdlanes-hook
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/hdlanes.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN_DIR/hdlanes" "$APP/Contents/MacOS/hdlanes"
cp "$BIN_DIR/hdlanes-hook" "$APP/Contents/Resources/bin/hdlanes-hook"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"
cp "$ICON_SRC" "$APP/Contents/Resources/hdlanes.icns"
# SwiftPM resource bundles (e.g. from dependencies), if any were produced.
for bundle in "$BIN_DIR"/*.bundle(N); do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
plutil -lint "$APP/Contents/Info.plist" >/dev/null

IDENTITY="${HDLANES_SIGN_IDENTITY-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
  echo "==> signing with: $IDENTITY"
  SIGN=(codesign --force --timestamp=none --sign "$IDENTITY")
else
  echo "==> signing ad-hoc"
  SIGN=(codesign --force --sign -)
fi
# Inner executable first, then the app bundle.
"${SIGN[@]}" "$APP/Contents/Resources/bin/hdlanes-hook"
"${SIGN[@]}" "$APP"
codesign --verify --strict "$APP"

RESULT="$APP"

if (( ZIP )); then
  ZIP_PATH="$ROOT/build/hdlanes-$VERSION.zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP" "$ZIP_PATH"
  echo "==> zipped $ZIP_PATH"
fi

if (( INSTALL )); then
  DEST="/Applications/hdlanes.app"
  echo "==> installing to $DEST"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$DEST"
  RESULT="$DEST"
fi

echo "$RESULT"
