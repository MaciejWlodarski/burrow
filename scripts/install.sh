#!/usr/bin/env zsh
# Installs Burrow.app (built by build_app.sh) into /Applications and links the
# `burrow` command-line tool into the first writable folder on PATH.
set -euo pipefail
cd "${0:A:h:h}"
SOURCE_APP="${PWD}/Burrow.app"
TARGET_APP="/Applications/Burrow.app"
[[ -d "${SOURCE_APP}" ]] || { echo "${SOURCE_APP} not found; run ./build_app.sh first" >&2; exit 1; }

rm -rf -- "${TARGET_APP}"
ditto "${SOURCE_APP}" "${TARGET_APP}"
codesign --verify --strict "${TARGET_APP}"
echo "Installed: ${TARGET_APP}"

CLI="${TARGET_APP}/Contents/Helpers/burrow"
for dir in /opt/homebrew/bin /usr/local/bin "${HOME}/.local/bin"; do
    if [[ -d "${dir}" && -w "${dir}" ]]; then
        ln -sf "${CLI}" "${dir}/burrow"
        echo "CLI: ${dir}/burrow -> ${CLI}"
        [[ ":${PATH}:" == *":${dir}:"* ]] || echo "Note: ${dir} is not in PATH" >&2
        exit 0
    fi
done
echo "No writable folder for the CLI link; run it as ${CLI}" >&2
