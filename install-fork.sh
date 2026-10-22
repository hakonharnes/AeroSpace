#!/usr/bin/env bash
# Builds AeroSpace.app and the aerospace CLI from the current checkout, and installs them over the Homebrew cask
# installation (/Applications/AeroSpace.app and the cask's CLI binary). `brew upgrade aerospace` reverts it.
#
# Usage: ./install-fork.sh [--codesign-identity <identity>] [--no-restart]
#   The identity defaults to the first "Apple Development" identity in the keychain. A stable identity is important:
#   macOS keeps the Accessibility permission only as long as the signature stays the same.
cd "$(dirname "$0")"
source ./script/setup.sh

identity=""
restart=1
while test $# -gt 0; do
    case $1 in
        --codesign-identity) identity="$2"; shift 2 ;;
        --no-restart) restart=0; shift ;;
        *) echo "Unknown option $1" > /dev/stderr; exit 1 ;;
    esac
done
if test -z "$identity"; then
    identity="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -o '"Apple Development: [^"]*"' | /usr/bin/head -1 | /usr/bin/tr -d '"')"
fi
if test -z "$identity"; then
    echo "No codesign identity found. Pass --codesign-identity" > /dev/stderr
    exit 1
fi
echo "Codesign identity: $identity"

version="$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)-fork"
out=.release-fork
rm -rf "$out" && mkdir -p "$out"

restore-generated-files() {
    git checkout Sources/Common/gitHashGenerated.swift Sources/Common/versionGenerated.swift xcode/AeroSpace.xcodeproj/project.pbxproj
}
trap restore-generated-files EXIT

./generate.sh --build-version "$version" --codesign-identity "$identity" --generate-git-hash
(
    cd xcode
    xcodebuild-pretty "../$out/xcodebuild.log" build \
        -scheme AeroSpace \
        -destination "generic/platform=macOS" \
        -configuration Release \
        -derivedDataPath .xcode-build
)
swift build -c release --product aerospace
cp -R xcode/.xcode-build/Build/Products/Release/AeroSpace.app "$out/"
cp "$(swift build -c release --product aerospace --show-bin-path)/aerospace" "$out/"
codesign -f -s "$identity" "$out/aerospace"

app=/Applications/AeroSpace.app
cli="$(readlink /opt/homebrew/bin/aerospace 2>/dev/null || echo /opt/homebrew/bin/aerospace)"

osascript -e 'tell application "AeroSpace" to quit' 2> /dev/null || true
sleep 1
rm -rf "$app"
cp -R "$out/AeroSpace.app" "$app"
cp "$out/aerospace" "$cli"
echo "Installed $("$app/Contents/MacOS/AeroSpace" --version) to $app and $cli"

if test $restart == 1; then
    open "$app"
fi
