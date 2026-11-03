#!/usr/bin/env zsh
# Installs Burrow.app (built by build_app.sh) into /Applications and links the
# `burrow` command-line tool into the first writable folder on PATH.
set -euo pipefail
cd "${0:A:h:h}"
SOURCE_APP="${PWD}/Burrow.app"
TARGET_APP="/Applications/Burrow.app"
[[ -d "${SOURCE_APP}" ]] || { echo "Brak ${SOURCE_APP}; uruchom najpierw ./build_app.sh" >&2; exit 1; }

rm -rf -- "${TARGET_APP}"
ditto "${SOURCE_APP}" "${TARGET_APP}"
codesign --verify --strict "${TARGET_APP}"
echo "Zainstalowano: ${TARGET_APP}"

CLI="${TARGET_APP}/Contents/Helpers/burrow"
for dir in /opt/homebrew/bin /usr/local/bin "${HOME}/.local/bin"; do
    if [[ -d "${dir}" && -w "${dir}" ]]; then
        ln -sf "${CLI}" "${dir}/burrow"
        echo "CLI: ${dir}/burrow -> ${CLI}"
        [[ ":${PATH}:" == *":${dir}:"* ]] || echo "Uwaga: ${dir} nie jest w PATH" >&2
        exit 0
    fi
done
echo "Nie znaleziono zapisywalnego folderu dla CLI; użyj: ${CLI}" >&2
