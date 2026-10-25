#!/bin/sh
# Builds Minis for your own iPhone with your own (free or paid) Apple ID, without changing the repo.
#
# Upstream's bundle id, App Group and iCloud container belong to upstream's team, and free teams
# cannot sign push, iCloud, WeatherKit or NFC. So this script copies src/ios to a work directory,
# rewrites those identifiers to your prefix there, drops the entitlements a free team cannot sign,
# then builds with automatic signing and installs on the device.
#
# Usage: scripts/ios-personal-device.sh --team <TEAM_ID> --prefix <com.you.minis> --device <id>
#        [--keep-push] [--keep-healthkit] [--keep-homekit]
# --keep-push keeps the push entitlement, which a paid team can sign; Pico notifications from
# minis-hostd need it (docs/remote-agent/b-push/apns.md).
# The device id is the identifier from `xcrun devicectl list devices`.
#
# One manual step the first time: command-line signing registers the bundle ids but not the App
# Group, so the first run fails with "Provisioning profile ... doesn't match ... application-groups".
# Open .build/personal-device/src/ios/Minis.xcodeproj in Xcode, and for the targets Minis,
# AgentWidgetExtension, MinisFileProvider and MinisShare pick your team in Signing & Capabilities and
# tick group.<prefix> under App Groups. Then run this script again.
set -eu

usage() {
	echo "usage: $0 --team <TEAM_ID> --prefix <com.you.minis> --device <device id> [--keep-push] [--keep-healthkit] [--keep-homekit]" >&2
	exit 2
}

team="" prefix="" device="" keep_push=0 keep_healthkit=0 keep_homekit=0
while [ $# -gt 0 ]; do
	case "$1" in
	--team) team="${2:-}"; shift 2 ;;
	--prefix) prefix="${2:-}"; shift 2 ;;
	--device) device="${2:-}"; shift 2 ;;
	--keep-push) keep_push=1; shift ;;
	--keep-healthkit) keep_healthkit=1; shift ;;
	--keep-homekit) keep_homekit=1; shift ;;
	*) usage ;;
	esac
done
[ -n "$team" ] && [ -n "$prefix" ] && [ -n "$device" ] || usage
case "$prefix" in
*[!A-Za-z0-9.-]* | .* | *.) echo "prefix must look like com.you.minis" >&2; exit 2 ;;
esac

repo=$(cd "$(dirname "$0")/.." && pwd)
work="${WORK_DIR:-$repo/.build/personal-device}"
derived="$work/DerivedData"

echo "Copying src/ios to $work" >&2
mkdir -p "$work/src"
rsync -a --delete --exclude '.build/' --exclude 'DerivedData/' --exclude 'xcuserdata/' "$repo/src/ios/" "$work/src/ios/"
# The project reaches outside src/ios for native deps (../../deps), build-phase scripts (../../scripts)
# and shared resources (../shared).
ln -sfn "$repo/deps" "$work/deps"
ln -sfn "$repo/scripts" "$work/scripts"
ln -sfn "$repo/src/shared" "$work/src/shared"

echo "Rewriting identifiers to $prefix" >&2
# Order matters: the longer group. and iCloud. ids first, then the plain bundle id prefix.
# No .build exclusion here: the work directory itself lives under .build/, and rsync already skipped
# the package build folders.
find "$work/src/ios" \( -name '*.swift' -o -name '*.plist' -o -name '*.entitlements' -o -name 'project.pbxproj' -o -name '*.xcconfig' \) \
	-print0 |
	xargs -0 sed -i '' \
		-e "s/group\.com\.openminis\.app/group.$prefix/g" \
		-e "s/iCloud\.com\.openminis\.app/iCloud.$prefix/g" \
		-e "s/com\.openminis\.app/$prefix/g" \
		-e "s/com\.openminis\.Minis/$prefix.Minis/g"

entitlements="$work/src/ios/Minis.entitlements"
for key in com.apple.developer.icloud-container-identifiers com.apple.developer.icloud-services \
	com.apple.developer.ubiquity-container-identifiers com.apple.developer.weatherkit \
	com.apple.developer.nfc.readersession.formats; do
	/usr/libexec/PlistBuddy -c "Delete :$key" "$entitlements" 2>/dev/null || true
done
if [ "$keep_push" -eq 0 ]; then
	/usr/libexec/PlistBuddy -c "Delete :aps-environment" "$entitlements" 2>/dev/null || true
	# The group exists only to share push keys with the extension, and a free team cannot sign one.
	/usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$entitlements" 2>/dev/null || true
	extension_entitlements="$work/src/ios/PicoNotificationService/PicoNotificationService.entitlements"
	if [ -f "$extension_entitlements" ]; then
		/usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$extension_entitlements" 2>/dev/null || true
	fi
fi
if [ "$keep_healthkit" -eq 0 ]; then
	/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.healthkit" "$entitlements" 2>/dev/null || true
	/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.healthkit.access" "$entitlements" 2>/dev/null || true
fi
if [ "$keep_homekit" -eq 0 ]; then
	/usr/libexec/PlistBuddy -c "Delete :com.apple.developer.homekit" "$entitlements" 2>/dev/null || true
fi
if grep -rq 'com\.openminis\.app' "$work/src/ios/Minis.xcodeproj/project.pbxproj"; then
	echo "identifier rewrite failed: com.openminis.app is still in the project" >&2
	exit 1
fi
echo "Entitlements left:" >&2
/usr/bin/plutil -p "$entitlements" >&2

echo "Building for device $device" >&2
xcodebuild -project "$work/src/ios/Minis.xcodeproj" -scheme Minis -configuration Debug \
	-destination "id=$device" -derivedDataPath "$derived" -allowProvisioningUpdates \
	DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
	build

app="$derived/Build/Products/Debug-iphoneos/Minis.app"
[ -d "$app" ] || { echo "no app at $app" >&2; exit 1; }
echo "Installing $app" >&2
xcrun devicectl device install app --device "$device" "$app"
echo "Installed. On first launch, trust the developer in Settings → General → VPN & Device Management." >&2
