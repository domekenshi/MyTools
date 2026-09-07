#!/bin/zsh
set -e

script_directory="${0:A:h}"
cd "$script_directory"

swift build -c release

app_path="$script_directory/FocusLoop.app"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/FocusLoop" "$app_path/Contents/MacOS/FocusLoop"

cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>FocusLoop</string>
	<key>CFBundleIdentifier</key>
	<string>local.mytools.focusloop</string>
	<key>CFBundleName</key>
	<string>集中ループタイマー</string>
	<key>CFBundleDisplayName</key>
	<string>集中ループタイマー</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$app_path"
echo "作成しました: $app_path"
