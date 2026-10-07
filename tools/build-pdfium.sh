#!/bin/sh
# Packages PDFium (Google's PDF engine, BSD-3 / Apache-2; prebuilt by
# github.com/bblanchon/pdfium-binaries, MIT) as Frameworks/PDFium.xcframework: a
# dynamic framework per platform (iPhone, iOS Simulator, Mac) with a module map, so
# Swift can `import PDFium`. The app embeds and signs it. Licenses go to
# Frameworks/PDFium-licenses. Re-run with another VERSION to upgrade.
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
VERSION=${VERSION:-8066}
WORK=$ROOT/build/pdfium
OUT=$ROOT/Frameworks/PDFium.xcframework
HEADERS="fpdfview.h fpdf_edit.h fpdf_text.h fpdf_save.h fpdf_doc.h fpdf_annot.h fpdf_formfill.h fpdf_ppo.h fpdf_transformpage.h fpdf_flatten.h fpdf_sysfontinfo.h fpdf_catalog.h fpdf_searchex.h"

mkdir -p "$WORK"

fetch() { # platform
    if [ ! -f "$WORK/$1/lib/libpdfium.dylib" ]; then
        echo "→ 下载 pdfium-$1（chromium/$VERSION）"
        curl -sfL --max-time 300 -o "$WORK/$1.tgz" \
            "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F$VERSION/pdfium-$1.tgz"
        rm -rf "${WORK:?}/$1" && mkdir -p "$WORK/$1" && tar xzf "$WORK/$1.tgz" -C "$WORK/$1"
    fi
}

plist() { # min-os platform
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>PDFium</string>
    <key>CFBundleIdentifier</key><string>org.pdfium.PDFium</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>PDFium</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$VERSION.0</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$2</string></array>
    <key>MinimumOSVersion</key><string>$1</string>
</dict></plist>
EOF
}

modulemap() {
    echo "framework module PDFium {"
    for header in $HEADERS; do echo "    header \"$header\""; done
    echo "    export *"
    echo "}"
}

# iOS frameworks are flat; a Mac framework needs Versions/A and symlinks.
package() { # platform kind(ios|mac) min-os plist-platform
    src=$WORK/$1
    fw=$WORK/frameworks/$1/PDFium.framework
    rm -rf "$fw"
    if [ "$2" = mac ]; then
        body=$fw/Versions/A
        mkdir -p "$body/Headers" "$body/Modules" "$body/Resources"
        plist "$3" "$4" > "$body/Resources/Info.plist"
        install_name=@rpath/PDFium.framework/Versions/A/PDFium
    else
        body=$fw
        mkdir -p "$body/Headers" "$body/Modules"
        plist "$3" "$4" > "$body/Info.plist"
        install_name=@rpath/PDFium.framework/PDFium
    fi
    cp "$src/lib/libpdfium.dylib" "$body/PDFium"
    install_name_tool -id "$install_name" "$body/PDFium"
    for header in $HEADERS; do cp "$src/include/$header" "$body/Headers/"; done
    modulemap > "$body/Modules/module.modulemap"
    if [ "$2" = mac ]; then
        ln -s A "$fw/Versions/Current"
        for item in PDFium Headers Modules Resources; do ln -s "Versions/Current/$item" "$fw/$item"; done
    fi
}

fetch ios-device-arm64
fetch ios-simulator-arm64
fetch mac-arm64
package ios-device-arm64 ios 17.0 iPhoneOS
package ios-simulator-arm64 ios 17.0 iPhoneSimulator
package mac-arm64 mac 13.0 MacOSX

rm -rf "$OUT"
xcodebuild -create-xcframework \
    -framework "$WORK/frameworks/ios-device-arm64/PDFium.framework" \
    -framework "$WORK/frameworks/ios-simulator-arm64/PDFium.framework" \
    -framework "$WORK/frameworks/mac-arm64/PDFium.framework" \
    -output "$OUT"
rm -rf "$ROOT/Frameworks/PDFium-licenses"
mkdir -p "$ROOT/Frameworks/PDFium-licenses"
cp "$WORK/ios-device-arm64/LICENSE" "$ROOT/Frameworks/PDFium-licenses/pdfium-binaries-LICENSE.txt"
cp "$WORK/ios-device-arm64/licenses/"* "$ROOT/Frameworks/PDFium-licenses/"
echo "✓ Frameworks/PDFium.xcframework（chromium/$VERSION）"
