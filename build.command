#!/bin/zsh
set -e

PROJECT_DIR="${0:A:h}"
FINAL_APP_DIR="$PROJECT_DIR/mp4-mov merge.app"
BUILD_DIR="$PROJECT_DIR/.swift-build"
APP_DIR="$BUILD_DIR/mp4-mov merge.app"
trap '/bin/rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" \
  "$BUILD_DIR/tmp" "$BUILD_DIR/module-cache"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

TMPDIR="$BUILD_DIR/tmp" /usr/bin/swiftc \
  -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit "$PROJECT_DIR/IconGenerator.swift" \
  -o "$BUILD_DIR/IconGenerator"
"$BUILD_DIR/IconGenerator" "$APP_DIR/Contents/Resources/AppIcon.icns"

for ARCH in arm64 x86_64; do
  TMPDIR="$BUILD_DIR/tmp" /usr/bin/swiftc \
    -swift-version 5 -O -target $ARCH-apple-macosx13.0 \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -framework AppKit \
    "$PROJECT_DIR/MergeEngine.swift" "$PROJECT_DIR/main.swift" \
    -o "$BUILD_DIR/MP4Merge-$ARCH"
done
/usr/bin/lipo -create "$BUILD_DIR/MP4Merge-arm64" "$BUILD_DIR/MP4Merge-x86_64" \
  -output "$APP_DIR/Contents/MacOS/MP4Merge"

/usr/bin/xattr -cr "$APP_DIR"
if /usr/bin/codesign --force --sign - "$APP_DIR" >/dev/null 2>&1; then
  print "Built and ad hoc signed: $FINAL_APP_DIR"
else
  print "Built without a signature: $FINAL_APP_DIR"
fi
/bin/rm -rf "$FINAL_APP_DIR"
/bin/mv "$APP_DIR" "$FINAL_APP_DIR"
/usr/bin/xattr -d com.apple.FinderInfo "$FINAL_APP_DIR" 2>/dev/null || true
