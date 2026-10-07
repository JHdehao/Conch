#!/bin/sh
# Builds Tailscale's embeddable client (github.com/tailscale/libtailscale, BSD-3) as
# static libraries for iPhone, the iOS Simulator (Apple silicon) and Mac, and wraps
# them in Frameworks/Tailscale.xcframework for Xcode. Needs Go (brew install go).
#
#   ./tools/build-tailscale.sh            # uses vendor/libtailscale, cloning it if missing
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
SRC=$ROOT/vendor/libtailscale
OUT=$ROOT/build/tailscale
[ -d "$SRC" ] || git clone --depth 1 https://github.com/tailscale/libtailscale.git "$SRC"
mkdir -p "$OUT"
export CGO_ENABLED=1
# Official proxy only: no mainland-China mirrors (the user's machines are always on overseas networks).
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
# Build with the Go version libtailscale pins; newer Go breaks go-json-experiment.
export GOTOOLCHAIN="${GOTOOLCHAIN:-go$(sed -n "s/^go //p" "$SRC/go.mod")}"

# Tailscale itself gets a small patch (vendor/libtailscale/patches): a patched copy of
# the module is built through a throwaway go.mod, so the module cache stays pristine.
TSVER=$(sed -n 's/^require tailscale.com //p' "$SRC/go.mod")
(cd "$SRC" && go mod download tailscale.com)
PRISTINE=$(cd "$SRC" && go list -m -f '{{.Dir}}' tailscale.com)
PATCHED=$OUT/tailscale.com@$TSVER
rm -rf "$PATCHED"
cp -R "$PRISTINE" "$PATCHED"
chmod -R u+w "$PATCHED"
for p in "$SRC"/patches/*.patch; do
    patch -s -p1 -d "$PATCHED" < "$p"
done
cp "$SRC/go.mod" "$OUT/go.mod"
cp "$SRC/go.sum" "$OUT/go.sum"
echo "replace tailscale.com => $PATCHED" >> "$OUT/go.mod"

build() { # name goos goarch sdk min-flag
    name=$1; sdk=$4; minflag=$5
    sdkpath=$(xcrun --sdk "$sdk" --show-sdk-path)
    clang=$(xcrun --sdk "$sdk" --find clang)
    wrapper=$OUT/cc-$name.sh
    printf '#!/bin/sh\nexec "%s" -arch arm64 -isysroot "%s" %s "$@"\n' "$clang" "$sdkpath" "$minflag" > "$wrapper"
    chmod +x "$wrapper"
    echo "→ $name"
    (cd "$SRC" && GOOS=$2 GOARCH=$3 CC=$wrapper go build -modfile="$OUT/go.mod" -trimpath -ldflags "-s -w" -tags "$([ "$2" = ios ] && echo ios || echo '')" \
        -buildmode=c-archive -o "$OUT/$name/libtailscale.a")
    # Headers in a folder named after the module, so they don't collide with other libraries'.
    rm -rf "$OUT/$name/include"
    mkdir -p "$OUT/$name/include/TailscaleC"
    cp "$SRC/tailscale.h" "$SRC/conch_tailscale.h" "$OUT/$name/include/TailscaleC/"
    rm -f "$OUT/$name/libtailscale.h"
    cat > "$OUT/$name/include/TailscaleC/module.modulemap" <<'EOF'
module TailscaleC {
    header "tailscale.h"
    header "conch_tailscale.h"
    link "resolv"
    export *
}
EOF
}

build ios ios arm64 iphoneos "-mios-version-min=18.0"
build ios-sim ios arm64 iphonesimulator "-mios-simulator-version-min=18.0"
build macos darwin arm64 macosx "-mmacosx-version-min=15.0"

rm -rf "$ROOT/Frameworks/Tailscale.xcframework"
mkdir -p "$ROOT/Frameworks"
xcodebuild -create-xcframework \
    -library "$OUT/ios/libtailscale.a" -headers "$OUT/ios/include" \
    -library "$OUT/ios-sim/libtailscale.a" -headers "$OUT/ios-sim/include" \
    -library "$OUT/macos/libtailscale.a" -headers "$OUT/macos/include" \
    -output "$ROOT/Frameworks/Tailscale.xcframework"
echo "✓ Frameworks/Tailscale.xcframework (libtailscale $(if [ -d "$SRC/.git" ]; then cd "$SRC" && git log -1 --format='%h, %cd' --date=short; else sed -n 2p "$SRC/UPSTREAM"; fi))"
