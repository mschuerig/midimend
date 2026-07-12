#!/bin/bash
# Local release driver. Signing stays on this Mac — the Developer ID
# private key is never exported, and the notary credentials live in the
# keychain.
#
# A release is two commands and two pushes:
#
#   packaging/release.sh prepare v0.2.0    # bump version, test, commit
#   git push
#   packaging/release.sh publish v0.2.0    # build, sign, notarize,
#                                          # GitHub release (mints the tag),
#                                          # formula rev, tap-clone sync
#   git -C ~/Projekte/homebrew-tap push    # ← this releases to users
#
# The formula-rev commit in this repo can ride along with the next
# ordinary push. If publish fails after the GitHub release exists, the
# remaining steps can be rerun alone: packaging/release.sh formula vX.Y.Z
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

set -euo pipefail

usage() {
    echo "usage: packaging/release.sh {prepare|publish|formula} v<version>" >&2
    exit 1
}

COMMAND="${1:-}"
TAG="${2:-}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
VERSION="${TAG#v}"

cd "$(git rev-parse --show-toplevel)"
DIST=".build/dist"
VERSION_FILE="Sources/midimend-cli/main.swift"
FORMULA="packaging/midimend.rb"
TARBALL_URL="https://github.com/mschuerig/midimend/archive/refs/tags/$TAG.tar.gz"
TAP_DIR="${TAP_DIR:-$HOME/Projekte/homebrew-tap}"

die() {
    echo "error: $*" >&2
    exit 1
}

require_clean_tree() {
    [ -z "$(git status --porcelain)" ] || die "working tree not clean"
}

cmd_prepare() {
    require_clean_tree
    [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "not on main"
    ! git rev-parse -q --verify "refs/tags/$TAG^{commit}" > /dev/null \
        || die "tag $TAG already exists"
    swift test
    sed -i '' -E "s/^let midimendVersion = \"[^\"]*\"/let midimendVersion = \"$VERSION\"/" "$VERSION_FILE"
    grep -q "^let midimendVersion = \"$VERSION\"" "$VERSION_FILE" \
        || die "could not update the version constant in $VERSION_FILE"
    swift build
    BUILT="$(.build/debug/midimend --version)"
    [ "$BUILT" = "midimend $VERSION" ] || die "binary says '$BUILT' after the bump"
    git commit -m "Bump version to $VERSION" "$VERSION_FILE"
    cat <<EOF

prepared: "Bump version to $VERSION" committed
next:
    git push
    packaging/release.sh publish $TAG
EOF
}

cmd_publish() {
    require_clean_tree
    grep -q "^let midimendVersion = \"$VERSION\"" "$VERSION_FILE" \
        || die "version constant is not $VERSION — run prepare first"
    git fetch origin main
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
        || die "HEAD is not origin/main — git push first"
    [ -z "$(git ls-remote origin "refs/tags/$TAG")" ] \
        || die "tag $TAG already on origin — if its release is published and only
       the formula step is missing, run: packaging/release.sh formula $TAG"
    security find-identity -v -p codesigning | grep -q "Developer ID Application" \
        || die "no 'Developer ID Application' certificate in the keychain"

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
    [ "$BUILT" = "midimend $VERSION" ] || die "tag is $TAG but the binary says: $BUILT"

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

    # --target mints the tag on GitHub at this (pushed) commit; no local
    # tag dance needed.
    gh release create "$TAG" "$DIST/midimend-$TAG-macos.zip" \
        --target "$(git rev-parse HEAD)" --generate-notes
    git fetch origin "refs/tags/$TAG:refs/tags/$TAG"
    echo "released: midimend-$TAG-macos.zip"

    cmd_formula
}

cmd_formula() {
    # Regenerated below from scratch; discard any partial edit so the
    # clean-tree check reflects everything else.
    git checkout -- "$FORMULA"
    require_clean_tree
    [ -d "$TAP_DIR/.git" ] || die "tap clone not found at $TAP_DIR"

    SHA="$(curl -fsL "$TARBALL_URL" | shasum -a 256 | cut -d' ' -f1)"
    [ -n "$SHA" ] || die "could not hash $TARBALL_URL"
    sed -i '' -E "s|^  url \".*\"$|  url \"$TARBALL_URL\"|" "$FORMULA"
    sed -i '' -E "s|^  sha256 \".*\"$|  sha256 \"$SHA\"|" "$FORMULA"
    grep -q "^  sha256 \"$SHA\"$" "$FORMULA" || die "could not update $FORMULA"
    if git diff --quiet -- "$FORMULA"; then
        echo "formula already at $TAG"
    else
        git commit -m "Rev the formula to $TAG" "$FORMULA"
    fi

    git -C "$TAP_DIR" pull --ff-only
    /bin/cp -f "$FORMULA" "$TAP_DIR/Formula/midimend.rb"
    if git -C "$TAP_DIR" diff --quiet -- Formula/midimend.rb; then
        echo "tap formula already at $TAG"
    else
        git -C "$TAP_DIR" commit -m "midimend $TAG" Formula/midimend.rb
    fi

    cat <<EOF

formula revved here and in $TAP_DIR
next:
    git -C $TAP_DIR push    # this is what releases to users
    git push                # project copy — can ride with the next push
EOF
}

case "$COMMAND" in
    prepare) cmd_prepare ;;
    publish) cmd_publish ;;
    formula) cmd_formula ;;
    *) usage ;;
esac
