#!/bin/zsh
set -e

PROJECT_DIR="${0:A:h}"
APP_NAME="mp4-mov merge.app"
VERSION="1.0"
DMG="$PROJECT_DIR/mp4-mov-merge-$VERSION.dmg"
STAGING="$PROJECT_DIR/.dmg-build"
trap '/bin/rm -rf "$STAGING"' EXIT

"$PROJECT_DIR/build.command"

/bin/rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$PROJECT_DIR/$APP_NAME" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

/usr/bin/hdiutil create -volname "mp4-mov merge $VERSION" -srcfolder "$STAGING" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
print "Made $DMG"
