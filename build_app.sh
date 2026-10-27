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
TARGET_ARCH="$(uname -m)"

cleanup_temp() {
    rm -rf -- "${BUILD_TMP_DIR}"
}
trap cleanup_temp EXIT

# Work only in this invocation's private directory. Keep the previous app until
# compilation, icon generation and signing have all succeeded.
echo "Budowanie ${APP_NAME} (${TARGET_ARCH})…"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${MODULE_CACHE}" "${ICONSET_DIR}"

xcrun swiftc \
    -module-cache-path "${MODULE_CACHE}" \
    -O \
    -target "${TARGET_ARCH}-apple-macosx14.0" \
    -sdk "${SDK_PATH}" \
    Sources/Burrow/Models/*.swift \
    Sources/Burrow/Engine/*.swift \
    Sources/Burrow/Views/*.swift \
    Sources/Burrow/BurrowApp.swift \
    -framework AppKit -framework SwiftUI -framework QuickLookUI \
    -framework QuickLookThumbnailing -framework CoreServices \
    -framework UniformTypeIdentifiers \
    -o "${MACOS_DIR}/${APP_NAME}"

cp Resources/Info.plist "${CONTENTS_DIR}/Info.plist"
xcrun swiftc \
    -module-cache-path "${MODULE_CACHE}" \
    -target "${TARGET_ARCH}-apple-macosx14.0" \
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
codesign --force --sign - --timestamp=none "${STAGED_APP}"
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
echo "Gotowe: ${APP_BUNDLE}"
