#!/bin/bash
# Build MX Switch.app. Falls back to the Command Line Tools toolchain when the
# full Xcode toolchain is unavailable, so a machine that has never opened Xcode
# still builds.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if ! /usr/bin/swiftc --version >/dev/null 2>&1; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    echo "Xcode is unavailable, building with the Command Line Tools toolchain."
fi

configuration="${CONFIGURATION:-release}"
version="$(cat VERSION)"
app="dist/MX Switch.app"
contents="$app/Contents"
# The daemon ships as a named bundle, not a bare binary: Input Monitoring lists
# whatever asked for access, and a bundle is something the user can recognise.
helper="$contents/Helpers/MX Switch Service.app"

Scripts/lint.sh
echo "Building (${configuration})..."
swift build -c "$configuration" --product mxswitchd
swift build -c "$configuration" --product MXSwitchApp
swift build -c "$configuration" --product mxswitch-tests
bin="$(swift build -c "$configuration" --show-bin-path)"

echo "Running tests..."
"$bin/mxswitch-tests"

echo "Assembling ${app}..."
rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources" "$helper/Contents/MacOS" "$helper/Contents/Resources"
cp "$bin/MXSwitchApp" "$contents/MacOS/MXSwitch"
cp "$bin/mxswitchd" "$helper/Contents/MacOS/MXSwitchService"

icon_key=''
if python3 -c "import PIL" >/dev/null 2>&1; then
    python3 Scripts/make-icon.py "$contents/Resources/AppIcon.icns"
    cp "$contents/Resources/AppIcon.icns" "$helper/Contents/Resources/AppIcon.icns"
    icon_key='<key>CFBundleIconFile</key><string>AppIcon</string>'
else
    echo "Pillow is not installed, shipping without an app icon."
fi

write_plist() {
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$2</string>
    <key>CFBundleDisplayName</key><string>$2</string>
    <key>CFBundleIdentifier</key><string>$3</string>
    <key>CFBundleExecutable</key><string>$4</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    $icon_key
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT licensed</string>
</dict>
</plist>
PLIST
}

write_plist "$contents/Info.plist" "MX Switch" "co.bernad.mxswitch" "MXSwitch"
write_plist "$helper/Contents/Info.plist" "MX Switch Service" "co.bernad.mxswitch.service" "MXSwitchService"

# Ad-hoc signatures are what Apple Silicon requires to run a locally built binary,
# and Input Monitoring keys its grant to the signature. The helper is signed first
# because signing the outer app seals it in place.
codesign --force --sign - --timestamp=none "$helper"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"

echo
echo "Built ${app}"
echo "Install it with:  make install"
