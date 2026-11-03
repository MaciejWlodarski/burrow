#!/usr/bin/env zsh
# Creates a stable local code-signing identity for Burrow, once per Mac.
#
# macOS ties privacy grants (Full Disk Access, Desktop/Documents access) to an
# app's code signature. An ad-hoc signature changes with every build, so each
# rebuild looked like a new app and lost its grants. Builds signed with this
# certificate keep one identity, so grants survive rebuilds.
#
# The identity lives in its own keychain, unlocked by a random password kept
# next to it (readable only by you), so builds never show a keychain prompt.
set -euo pipefail

SIGNING_DIR="${BURROW_SIGNING_DIR:-${HOME}/Library/Application Support/Burrow/Signing}"
KEYCHAIN="${SIGNING_DIR}/burrow-signing.keychain-db"
PASSWORD_FILE="${SIGNING_DIR}/keychain-password"
IDENTITY="Burrow Local Signing"

if [[ -f "${KEYCHAIN}" && -f "${PASSWORD_FILE}" ]]; then
    security unlock-keychain -p "$(<"${PASSWORD_FILE}")" "${KEYCHAIN}"
    if security find-certificate -c "${IDENTITY}" "${KEYCHAIN}" >/dev/null 2>&1; then
        echo "Tożsamość \"${IDENTITY}\" już istnieje: ${KEYCHAIN}"
        exit 0
    fi
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp/}burrow-signing.XXXXXX")"
trap 'rm -rf -- "${WORK_DIR}"' EXIT
mkdir -p "${SIGNING_DIR}"
chmod 700 "${SIGNING_DIR}"
rm -f -- "${KEYCHAIN}" "${PASSWORD_FILE}"
(umask 077; /usr/bin/openssl rand -hex 32 > "${PASSWORD_FILE}")
PASSWORD="$(<"${PASSWORD_FILE}")"

cat > "${WORK_DIR}/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${IDENTITY}
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
# LibreSSL writes a PKCS#12 file that `security import` accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -sha256 \
    -config "${WORK_DIR}/cert.conf" -keyout "${WORK_DIR}/key.pem" -out "${WORK_DIR}/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "${WORK_DIR}/key.pem" -in "${WORK_DIR}/cert.pem" \
    -name "${IDENTITY}" -passout "pass:${PASSWORD}" -out "${WORK_DIR}/identity.p12"

security create-keychain -p "${PASSWORD}" "${KEYCHAIN}"
security set-keychain-settings "${KEYCHAIN}"
security unlock-keychain -p "${PASSWORD}" "${KEYCHAIN}"
security import "${WORK_DIR}/identity.p12" -k "${KEYCHAIN}" -P "${PASSWORD}" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${PASSWORD}" "${KEYCHAIN}" >/dev/null
echo "Utworzono tożsamość \"${IDENTITY}\": ${KEYCHAIN}"
