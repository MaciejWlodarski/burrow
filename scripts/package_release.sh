#!/usr/bin/env zsh
# Packages Burrow.app into dist/Burrow.dmg and dist/Burrow.zip with checksums.
# The asset names stay fixed so .../releases/latest/download/Burrow.dmg always
# points at the newest release.
set -euo pipefail
cd "${0:A:h}/.."

APP="Burrow.app"
[[ -d "${APP}" ]] || { echo "${APP} not found; run ./build_app.sh first" >&2; exit 1; }
rm -rf dist
mkdir -p dist
STAGE="$(mktemp -d "${TMPDIR:-/tmp/}burrow-dmg.XXXXXX")"
trap 'rm -rf -- "${STAGE}"' EXIT

ditto "${APP}" "${STAGE}/Burrow.app"
ln -s /Applications "${STAGE}/Applications"
hdiutil create -volname "Burrow" -srcfolder "${STAGE}" -fs HFS+ -format UDZO -ov dist/Burrow.dmg >/dev/null
ditto -c -k --keepParent "${APP}" dist/Burrow.zip
(cd dist && shasum -a 256 Burrow.dmg Burrow.zip > SHA256SUMS.txt)
cat dist/SHA256SUMS.txt
