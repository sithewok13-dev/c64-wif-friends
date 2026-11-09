#!/bin/bash
# Builds C64 wif Friends for iPhone on a Mac: the VICE x64sc core as a static
# library, then the app, then an unsigned IPA in build/C64wifFriends.ipa.
#   VERSION=0.1 BUILD=1 ios/build.sh
set -euo pipefail

VICE_REPO=https://github.com/libretro/vice-libretro.git
VICE_COMMIT=76cde0b2cc4e52106618f2cc5d9d1112d9205c89   # pinned; change on purpose only
MIN_IOS=15.0
VERSION=${VERSION:-0.1}
BUILD=${BUILD:-0}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC="xcrun --sdk iphoneos clang -arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN_IOS"
mkdir -p "$OUT"

# 1. The VICE core (kept between runs by the CI cache).
if [ ! -f "$OUT/libvice.a" ]; then
   rm -rf "$OUT/vice-libretro"
   git init -q "$OUT/vice-libretro"
   git -C "$OUT/vice-libretro" fetch -q --depth 1 "$VICE_REPO" "$VICE_COMMIT"
   git -C "$OUT/vice-libretro" checkout -q FETCH_HEAD
   # zlib's old classic-Mac check also fires on iOS and breaks the SDK's
   # own fdopen() declaration.
   sed -i '' 's/#if defined(MACOS) || defined(TARGET_OS_MAC)/#if defined(MACOS)/' \
      "$OUT/vice-libretro/deps/libz/zutil.h"
   echo "Building VICE (log: build/vice-build.log)..."
   # The makefile links a .dylib at the end; we only need the objects.
   if ! make -C "$OUT/vice-libretro" -j"$(sysctl -n hw.ncpu)" EMUTYPE=x64sc platform=ios-arm64 \
        IOSSDK="$SDK" MINVERSION="-miphoneos-version-min=$MIN_IOS" > "$OUT/vice-build.log" 2>&1; then
      echo "::warning::VICE's own make step failed; last lines:"
      grep -E "error|Error" "$OUT/vice-build.log" | tail -40 || true
      tail -20 "$OUT/vice-build.log"
      # Only the final .dylib link may fail; any compile error is fatal.
      if grep -q "Error 1" "$OUT/vice-build.log" && ! grep -q "_libretro_ios.dylib\] Error" "$OUT/vice-build.log"; then
         echo "::error::VICE failed to compile"; exit 1
      fi
   fi
   find "$OUT/vice-libretro/build" -name '*.o' > "$OUT/vice-objects.txt"
   echo "VICE objects: $(wc -l < "$OUT/vice-objects.txt")"
   [ -s "$OUT/vice-objects.txt" ] || { echo "::error::VICE did not compile"; exit 1; }
   libtool -static -o "$OUT/libvice.a" -filelist "$OUT/vice-objects.txt" 2> "$OUT/libtool.log" || { cat "$OUT/libtool.log"; exit 1; }
   rm -rf "$OUT/vice-libretro"
fi

# 2. The app.
APP="$OUT/Payload/C64wifFriends.app"
rm -rf "$OUT/Payload" "$OUT/obj"
mkdir -p "$APP" "$OUT/obj"
$CC -O2 -std=gnu11 -Wall -I"$ROOT/src" -c "$ROOT/src/frontend.c" -o "$OUT/obj/frontend.o"
$CC -O2 -std=gnu11 -Wall -I"$ROOT/src" -c "$ROOT/src/netcodec.c" -o "$OUT/obj/netcodec.o"
for m in main TouchOverlay Net; do
   $CC -O2 -fobjc-arc -fmodules -Wall -I"$ROOT/src" -I"$ROOT/ios" -c "$ROOT/ios/$m.m" -o "$OUT/obj/$m.o"
done
$CC -o "$APP/C64wifFriends" "$OUT"/obj/*.o "$OUT/libvice.a" \
   -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
   -framework AVFoundation -framework AudioToolbox -framework UniformTypeIdentifiers -framework Network \
   -lc++ -lz -lcompression -dead_strip

sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" "$ROOT/ios/Info.plist" > "$APP/Info.plist"
plutil -lint "$APP/Info.plist"
plutil -convert binary1 "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"
cp "$ROOT"/ios/icons/AppIcon60x60@*.png "$ROOT"/ios/icons/*~ipad.png "$APP/"
cp "$ROOT/COPYING" "$APP/COPYING.txt"

(cd "$OUT" && rm -f C64wifFriends.ipa && zip -qr C64wifFriends.ipa Payload)
ls -l "$OUT/C64wifFriends.ipa"
