#!/usr/bin/env zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp/}burrow-terminal-live.XXXXXX")"
# Failed runs retain diagnostics. The Swift harness drains owned workers before exit.
trap 'result=$?; if [[ ${result} -eq 0 ]]; then rm -rf -- "${TEST_TMP_DIR}"; else print -u2 "Integration fixtures retained: ${TEST_TMP_DIR}"; fi' EXIT
export BURROW_TEST_ROOT="${TEST_TMP_DIR}/fixtures"
export HOME="${TEST_TMP_DIR}/home"
export CFFIXED_USER_HOME="${HOME}"
mkdir -p "${BURROW_TEST_ROOT}" "${HOME}" "${TEST_TMP_DIR}/module-cache"
sed '/^@main$/d' Sources/Burrow/BurrowApp.swift > "${TEST_TMP_DIR}/App.swift"
xcrun swiftc -parse-as-library -D BURROW_TESTING \
    -module-cache-path "${BURROW_MODULE_CACHE:-${TEST_TMP_DIR}/module-cache}" \
    -target "$(uname -m)-apple-macosx14.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    Sources/Burrow/Models/*.swift Sources/Burrow/Engine/*.swift \
    Sources/Burrow/Views/*.swift "${TEST_TMP_DIR}/App.swift" \
    scripts/test_terminal_live_integration.swift -o "${TEST_TMP_DIR}/terminal-live-tests"
"${TEST_TMP_DIR}/terminal-live-tests"
