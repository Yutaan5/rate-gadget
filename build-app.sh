#!/bin/sh
# Builds RateGadget.app: a plain Swift Package executable wrapped into a
# minimal macOS app bundle (no Xcode project needed).
set -eu

cd "$(dirname "$0")"

APP_NAME="RateGadget"
BUNDLE_ID="dev.tsuji.rategadget"
OUT_APP="${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"

echo "==> assembling ${OUT_APP}"
rm -rf "$OUT_APP"
mkdir -p "$OUT_APP/Contents/MacOS" "$OUT_APP/Contents/Resources"

cp "$BIN_PATH" "$OUT_APP/Contents/MacOS/${APP_NAME}"
cp Resources/claude-statusline.sh "$OUT_APP/Contents/Resources/claude-statusline.sh"

cat > "$OUT_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$OUT_APP"

echo "==> done: $(pwd)/${OUT_APP}"
echo "    初回起動はGatekeeperに警告される場合があります。"
echo "    その場合はFinderで右クリック→「開く」を選んでください。"
