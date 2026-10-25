#!/usr/bin/env zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp/}better-finder-tests.XXXXXX")"
# cfprefsd writes test suites to the real preferences folder even with HOME
# overridden, and leaves empty plists after removePersistentDomain. Remove them.
REAL_PREFERENCES="${HOME}/Library/Preferences"
cleanup_tests() {
    rm -rf -- "${TEST_TMP_DIR}"
    setopt local_options null_glob
    rm -f -- "${REAL_PREFERENCES}"/com.betterfinder.tests.*.plist \
        "${REAL_PREFERENCES}"/BetterFinder.SessionTests.*.plist \
        "${REAL_PREFERENCES}"/bf-indexing-tests-*.plist \
        "${REAL_PREFERENCES}"/bf-restored-settings-*.plist \
        "${REAL_PREFERENCES}"/bf-cache-off-settings-*.plist
}
trap cleanup_tests EXIT
TEST_MODULE_CACHE="${BETTERFINDER_MODULE_CACHE:-${TEST_TMP_DIR}/module-cache}"
mkdir -p "${TEST_MODULE_CACHE}"
# Tests compile the production paths but isolate singleton startup and defaults.
export BETTERFINDER_TEST_ROOT="${TEST_TMP_DIR}/fixtures"
export HOME="${TEST_TMP_DIR}/home"
export CFFIXED_USER_HOME="${HOME}"
mkdir -p "${BETTERFINDER_TEST_ROOT}" "${HOME}"
xcrun swiftc -parse-as-library -D BETTERFINDER_TESTING \
    -module-cache-path "${TEST_MODULE_CACHE}" \
    -target "$(uname -m)-apple-macosx14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    Sources/BetterFinder/Models/*.swift Sources/BetterFinder/Engine/*.swift \
    Sources/BetterFinder/Views/*.swift \
    Tests/BetterFinderTests/*.swift \
    -o "${TEST_TMP_DIR}/regression-tests"
"${TEST_TMP_DIR}/regression-tests"

xcrun swift -module-cache-path "${TEST_MODULE_CACHE}" scripts/test_file_operations.swift
