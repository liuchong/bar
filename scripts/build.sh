set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release -j 2
binary_dir=$(swift build -c release --show-bin-path)
app="dist/Bar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc Sources/Bar/DrawerArtwork.swift scripts/make-icon.swift -o .build/make-icon
.build/make-icon .build/Bar.iconset
iconutil -c icns .build/Bar.iconset -o "$app/Contents/Resources/Bar.icns"
cp "$binary_dir/Bar" "$app/Contents/MacOS/Bar"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --options runtime --sign "${BAR_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
echo "Built: $app"
