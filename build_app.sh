#!/usr/bin/env zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
cd "${PROJECT_DIR}"
APP_NAME="Burrow"
APP_BUNDLE="${PROJECT_DIR}/${APP_NAME}.app"
BUILD_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp/}burrow-build.XXXXXX")"
STAGED_APP="${BUILD_TMP_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${STAGED_APP}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
MODULE_CACHE="${BURROW_MODULE_CACHE:-${BUILD_TMP_DIR}/swift-module-cache}"
ICONSET_DIR="${BUILD_TMP_DIR}/${APP_NAME}.iconset"
ICON_GEN_BIN="${BUILD_TMP_DIR}/generate-icon"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
# Release builds set BURROW_ARCHS="arm64 x86_64" for a universal app.
ARCHS=(${=BURROW_ARCHS:-$(uname -m)})

# A stable identity (scripts/setup_signing.sh) keeps macOS privacy grants such
# as Full Disk Access across rebuilds. Without it the build is signed ad hoc and
# every rebuild needs those grants again.
SIGNING_DIR="${BURROW_SIGNING_DIR:-${HOME}/Library/Application Support/Burrow/Signing}"
SIGNING_KEYCHAIN="${SIGNING_DIR}/burrow-signing.keychain-db"
SIGNING_IDENTITY="${BURROW_SIGNING_IDENTITY:-Burrow Local Signing}"
SIGN_ARGS=(--sign -)
if [[ -f "${SIGNING_KEYCHAIN}" && -f "${SIGNING_DIR}/keychain-password" ]] \
    && security unlock-keychain -p "$(<"${SIGNING_DIR}/keychain-password")" "${SIGNING_KEYCHAIN}" 2>/dev/null; then
    SIGN_ARGS=(--keychain "${SIGNING_KEYCHAIN}" --sign "${SIGNING_IDENTITY}")
else
    echo "Note: no stable signing identity; run scripts/setup_signing.sh, or macOS permissions must be granted again after every build." >&2
fi

cleanup_temp() {
    rm -rf -- "${BUILD_TMP_DIR}"
}
trap cleanup_temp EXIT

# Work only in this invocation's private directory. Keep the previous app until
# compilation, icon generation and signing have all succeeded.
echo "Building ${APP_NAME} (${ARCHS[*]})…"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${MODULE_CACHE}" "${ICONSET_DIR}" "${CONTENTS_DIR}/Helpers"

# Compiles one executable for every architecture and merges the slices.
compile() {
    local output="$1"; shift
    local slices=()
    for arch in "${ARCHS[@]}"; do
        xcrun swiftc \
            -module-cache-path "${MODULE_CACHE}/${arch}" \
            -O \
            -target "${arch}-apple-macosx14.0" \
            -sdk "${SDK_PATH}" \
            "$@" \
            -o "${output}.${arch}"
        slices+=("${output}.${arch}")
    done
    lipo -create "${slices[@]}" -output "${output}"
    rm -f -- "${slices[@]}"
}

compile "${MACOS_DIR}/${APP_NAME}" \
    Sources/Burrow/Models/*.swift \
    Sources/Burrow/Engine/*.swift \
    Sources/Burrow/Views/*.swift \
    Sources/Burrow/BurrowApp.swift \
    -framework AppKit -framework SwiftUI -framework QuickLookUI \
    -framework QuickLookThumbnailing -framework CoreServices \
    -framework UniformTypeIdentifiers

# The `burrow` command-line tool shares the disk map's scanner. Helpers/ keeps
# it apart from MacOS/Burrow on a case-insensitive disk.
compile "${CONTENTS_DIR}/Helpers/burrow" \
    Sources/Burrow/Engine/DiskTree.swift \
    Sources/Burrow/Models/FileItem.swift \
    Sources/BurrowCLI/*.swift
codesign --force "${SIGN_ARGS[@]}" --identifier com.burrow.cli --timestamp=none "${CONTENTS_DIR}/Helpers/burrow"

cp Resources/Info.plist "${CONTENTS_DIR}/Info.plist"
if [[ -n "${BURROW_VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "${BURROW_VERSION}" "${CONTENTS_DIR}/Info.plist"
fi
if [[ -n "${BURROW_BUILD_NUMBER:-}" ]]; then
    plutil -replace CFBundleVersion -string "${BURROW_BUILD_NUMBER}" "${CONTENTS_DIR}/Info.plist"
fi
for lproj in Resources/*.lproj(N); do
    cp -R "${lproj}" "${RESOURCES_DIR}/"
done
xcrun swiftc \
    -module-cache-path "${MODULE_CACHE}" \
    -target "$(uname -m)-apple-macosx14.0" \
    -sdk "${SDK_PATH}" \
    scripts/generate_icon.swift -framework AppKit -o "${ICON_GEN_BIN}"
"${ICON_GEN_BIN}" "${ICONSET_DIR}/icon_512x512@2x.png"
sips -z 1024 1024 "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null
for icon_size in 16 32 128 256 512; do
    sips -z "${icon_size}" "${icon_size}" "${ICONSET_DIR}/icon_512x512@2x.png" \
        --out "${ICONSET_DIR}/icon_${icon_size}x${icon_size}.png" >/dev/null
    if [[ "${icon_size}" -lt 512 ]]; then
        retina_size=$((icon_size * 2))
        sips -z "${retina_size}" "${retina_size}" "${ICONSET_DIR}/icon_512x512@2x.png" \
            --out "${ICONSET_DIR}/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
    fi
done
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
codesign --force "${SIGN_ARGS[@]}" --timestamp=none "${STAGED_APP}"
codesign --verify --strict "${STAGED_APP}"

if [[ -e "${APP_BUNDLE}" ]]; then
    mv -- "${APP_BUNDLE}" "${BUILD_TMP_DIR}/previous.app"
fi
if ! mv -- "${STAGED_APP}" "${APP_BUNDLE}"; then
    if [[ -e "${BUILD_TMP_DIR}/previous.app" ]]; then
        mv -- "${BUILD_TMP_DIR}/previous.app" "${APP_BUNDLE}"
    fi
    exit 1
fi
echo "Built: ${APP_BUNDLE}"
