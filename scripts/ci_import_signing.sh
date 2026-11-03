#!/usr/bin/env zsh
# Imports the release signing identity from CI secrets into a private keychain
# laid out the way build_app.sh expects (BURROW_SIGNING_DIR).
#
#   BURROW_SIGNING_P12           base64 of a PKCS#12 file with the identity
#   BURROW_SIGNING_P12_PASSWORD  its password
#   BURROW_SIGNING_DIR           where to create the keychain
#
# Without the secrets it does nothing and the build is signed ad hoc.
set -euo pipefail

if [[ -z "${BURROW_SIGNING_P12:-}" || -z "${BURROW_SIGNING_P12_PASSWORD:-}" ]]; then
    echo "No signing secrets; the build will be signed ad hoc."
    exit 0
fi

DIR="${BURROW_SIGNING_DIR:?BURROW_SIGNING_DIR is required}"
KEYCHAIN="${DIR}/burrow-signing.keychain-db"
mkdir -p "${DIR}"
chmod 700 "${DIR}"
(umask 077; /usr/bin/openssl rand -hex 32 > "${DIR}/keychain-password")
PASSWORD="$(<"${DIR}/keychain-password")"
print -rn -- "${BURROW_SIGNING_P12}" | base64 --decode > "${DIR}/identity.p12"

security create-keychain -p "${PASSWORD}" "${KEYCHAIN}"
security set-keychain-settings "${KEYCHAIN}"
security unlock-keychain -p "${PASSWORD}" "${KEYCHAIN}"
security import "${DIR}/identity.p12" -k "${KEYCHAIN}" -P "${BURROW_SIGNING_P12_PASSWORD}" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${PASSWORD}" "${KEYCHAIN}" >/dev/null
rm -f -- "${DIR}/identity.p12"
security find-identity -p codesigning "${KEYCHAIN}" | sed -n '1,3p'
