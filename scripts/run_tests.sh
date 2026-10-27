#!/usr/bin/env zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp/}burrow-tests.XXXXXX")"
# cfprefsd writes test suites to the real preferences folder even with HOME
# overridden, and leaves empty plists after removePersistentDomain. Remove them.
REAL_PREFERENCES="${HOME}/Library/Preferences"
cleanup_tests() {
    rm -rf -- "${TEST_TMP_DIR}"
    setopt local_options null_glob
    rm -f -- "${REAL_PREFERENCES}"/com.burrow.tests.*.plist \
        "${REAL_PREFERENCES}"/Burrow.SessionTests.*.plist \
        "${REAL_PREFERENCES}"/bf-indexing-tests-*.plist \
        "${REAL_PREFERENCES}"/bf-restored-settings-*.plist \
        "${REAL_PREFERENCES}"/bf-cache-off-settings-*.plist
}
trap cleanup_tests EXIT
TEST_MODULE_CACHE="${BURROW_MODULE_CACHE:-${TEST_TMP_DIR}/module-cache}"
mkdir -p "${TEST_MODULE_CACHE}"
# Tests compile the production paths but isolate singleton startup and defaults.
export BURROW_TEST_ROOT="${TEST_TMP_DIR}/fixtures"
export HOME="${TEST_TMP_DIR}/home"
export CFFIXED_USER_HOME="${HOME}"
mkdir -p "${BURROW_TEST_ROOT}" "${HOME}"
xcrun swiftc -parse-as-library -D BURROW_TESTING \
    -module-cache-path "${TEST_MODULE_CACHE}" \
    -target "$(uname -m)-apple-macosx14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    Sources/Burrow/Models/*.swift Sources/Burrow/Engine/*.swift \
    Sources/Burrow/Views/*.swift \
    Tests/BurrowTests/*.swift \
    -o "${TEST_TMP_DIR}/regression-tests"
"${TEST_TMP_DIR}/regression-tests"

xcrun swift -module-cache-path "${TEST_MODULE_CACHE}" scripts/test_file_operations.swift
