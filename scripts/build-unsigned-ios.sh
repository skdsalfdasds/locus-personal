#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p outputs
xcodegen generate
xcodebuild \
  -project Locus.xcodeproj \
  -scheme Locus \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  DEVELOPMENT_TEAM='' \
  build 2>&1 | tee outputs/build.log
test -d build/DerivedData/Build/Products/Release-iphoneos/Locus.app
# A new temporary staging directory avoids stale app files from earlier builds.
staging="$(mktemp -d)"
mkdir -p "$staging/Payload"
ditto build/DerivedData/Build/Products/Release-iphoneos/Locus.app "$staging/Payload/Locus.app"
ditto -c -k --keepParent "$staging/Payload" outputs/Locus-personal-unsigned.ipa
unzip -t outputs/Locus-personal-unsigned.ipa
shasum -a 256 outputs/Locus-personal-unsigned.ipa
