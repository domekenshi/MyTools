#!/bin/zsh
set -e

script_directory="${0:A:h}"
cd "$script_directory"

swift build -c release

app_path="$script_directory/ScreenRecorder.app"
asset_info_path="$app_path/Contents/AppIcon-info.plist"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/ScreenRecorder" "$app_path/Contents/MacOS/ScreenRecorder"

xcrun actool \
  --compile "$app_path/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 15.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$asset_info_path" \
  "$script_directory/Assets/AppIcon.xcassets"
rm "$asset_info_path"

cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>ScreenRecorder</string>
	<key>CFBundleIdentifier</key>
	<string>local.mytools.screenrecorder</string>
	<key>CFBundleName</key>
	<string>ScreenRecorder</string>
	<key>CFBundleDisplayName</key>
	<string>ScreenRecorder</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon.icns</string>
	<key>CFBundleIconName</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>4</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>画面録画にマイク音声を含めるために使用します。</string>
	<key>NSScreenCaptureUsageDescription</key>
	<string>画面とシステム音声を動画として保存するために使用します。</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# An ad-hoc signature normally uses the binary hash as its designated
# requirement. That hash changes on every rebuild, causing macOS to forget an
# already granted Screen Recording permission.  Pin the requirement to this
# bundle identifier so a rebuilt copy remains the same app to TCC.
codesign --force --deep --sign - \
  --identifier local.mytools.screenrecorder \
  --requirements '=designated => identifier "local.mytools.screenrecorder"' \
  "$app_path"

rm -rf /Applications/ScreenRecorder.app
ditto "$app_path" /Applications/ScreenRecorder.app

echo "作成しました: $app_path"
