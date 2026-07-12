#!/bin/bash
# Local release: build, sign, notarize, and publish a GitHub release.
# Signing stays on this Mac — the Developer ID private key is never
# exported, and the notary credentials live in the keychain.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in the login keychain
#      (developer.apple.com -> Certificates; this is a different type
#      than the Apple Distribution certificate used for the App Store).
#   2. An App Store Connect API key (appstoreconnect.apple.com ->
#      Users and Access -> Integrations -> App Store Connect API ->
#      Team Keys; the Developer role suffices), stored once with
#        xcrun notarytool store-credentials midimend \
#          --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-ID>
#      (the downloaded .p8 can be deleted afterwards).
#   3. gh auth login
#
# Usage: packaging/release.sh v0.1.0     (a pushed tag, checked out)

set -euo pipefail

TAG="${1:?usage: packaging/release.sh v<version> (a pushed tag, checked out)}"
cd "$(git rev-parse --show-toplevel)"
DIST=".build/dist"

if [ "$(git rev-parse HEAD)" != "$(git rev-parse "$TAG^{commit}")" ]; then
    echo "error: HEAD is not at $TAG — check out the tag first" >&2
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "error: no 'Developer ID Application' certificate in the keychain" >&2
    exit 1
fi

# Per-arch native-SwiftPM builds + lipo: the combined --arch form uses
# the Xcode build system, which doesn't support embedInCode resources.
swift build -c release --triple arm64-apple-macosx
swift build -c release --triple x86_64-apple-macosx
rm -rf "$DIST"
mkdir -p "$DIST"
lipo -create -output "$DIST/midimend" \
    .build/arm64-apple-macosx/release/midimend \
    .build/x86_64-apple-macosx/release/midimend

BUILT="$("$DIST/midimend" --version)"
if [ "$BUILT" != "midimend ${TAG#v}" ]; then
    echo "error: tag is $TAG but the binary says: $BUILT" >&2
    echo "bump midimendVersion in Sources/midimend-cli/main.swift" >&2
    exit 1
fi

# Hardened runtime + the allow-jit entitlement JavaScriptCore's JIT needs.
codesign --force --options runtime --timestamp \
    --entitlements packaging/midimend.entitlements \
    --sign "Developer ID Application" \
    "$DIST/midimend"
codesign --verify --strict "$DIST/midimend"

# A bare executable cannot be stapled; Gatekeeper fetches the ticket online.
ditto -c -k "$DIST/midimend" "$DIST/notarize.zip"
xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile midimend --wait

STAGE="$DIST/midimend-$TAG"
mkdir -p "$STAGE"
cp "$DIST/midimend" README.md LICENSE packaging/midimend.1 "$STAGE/"
cp -R examples packaging/completions "$STAGE/"
ditto -c -k --keepParent "$STAGE" "$DIST/midimend-$TAG-macos.zip"

gh release create "$TAG" "$DIST/midimend-$TAG-macos.zip" --generate-notes
echo "released: midimend-$TAG-macos.zip"
