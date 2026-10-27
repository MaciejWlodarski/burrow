#!/usr/bin/env zsh
set -euo pipefail
cd "${0:A:h:h}"
PREVIEW_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp/}burrow-preview.XXXXXX")"
trap 'rm -rf -- "${PREVIEW_TMP_DIR}"' EXIT
PREVIEW_OUTPUT="${PWD}/.build/previews"
PREVIEW_APP="${PREVIEW_TMP_DIR}/BurrowPreview.app"
mkdir -p "${PREVIEW_OUTPUT}" "${PWD}/.build/preview-module-cache" "${PREVIEW_APP}/Contents/MacOS"
cp Resources/Info.plist "${PREVIEW_APP}/Contents/Info.plist"
plutil -replace CFBundleExecutable -string NativePreview "${PREVIEW_APP}/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.burrow.preview "${PREVIEW_APP}/Contents/Info.plist"
rm -f -- "${PREVIEW_OUTPUT}/verification.txt"
# Keep the real App/Scene and command definitions; the harness supplies main().
sed '/^@main$/d' Sources/Burrow/BurrowApp.swift > "${PREVIEW_TMP_DIR}/App.swift"
xcrun swiftc -parse-as-library \
    -module-cache-path "${PWD}/.build/preview-module-cache" \
    -target "$(uname -m)-apple-macosx14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    Sources/Burrow/Models/*.swift Sources/Burrow/Engine/*.swift Sources/Burrow/Views/*.swift \
    "${PREVIEW_TMP_DIR}/App.swift" scripts/preview_app.swift -o "${PREVIEW_APP}/Contents/MacOS/NativePreview"
codesign --force --sign - --timestamp=none "${PREVIEW_APP}"
open -n -W -F --stdout "${PREVIEW_TMP_DIR}/preview.log" --stderr "${PREVIEW_TMP_DIR}/preview.err" \
    --env "BURROW_PREVIEW_OUTPUT=${PREVIEW_OUTPUT}" "${PREVIEW_APP}"
cat "${PREVIEW_TMP_DIR}/preview.log" "${PREVIEW_TMP_DIR}/preview.err"
[[ -f "${PREVIEW_OUTPUT}/verification.txt" ]] && [[ "$(<"${PREVIEW_OUTPUT}/verification.txt")" == PASS* ]]
