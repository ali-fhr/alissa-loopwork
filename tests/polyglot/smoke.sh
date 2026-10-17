#!/bin/bash
# Per-language build-and-test smoke for the POLYGLOT variant. Runs INSIDE the
# container as root (see tests/run.sh and ci.yml), with the sample projects in
# this directory mounted read-only at /polyglot. Every sample is compiled and
# tested as the unprivileged `alissa` user in a LOGIN shell — the same PATH a
# tmux-spawned worker session gets (Debian's /etc/profile resets PATH; the
# image's /etc/profile.d drop-in must put the toolchains back).
#
# Unlike tests/smoke.sh this needs NETWORK for one step: `gradle test` resolves
# the Kotlin Gradle plugin and kotlin-test/JUnit from the Gradle Plugin Portal
# and Maven Central. C, C++, Go and Rust are offline (no third-party deps).
set -euo pipefail

SRC="${POLYGLOT_SRC:-/polyglot}"
WORK="$(mktemp -d /tmp/polyglot-smoke.XXXXXX)"
cp -r "${SRC}/." "${WORK}/"
chown -R alissa:alissa "${WORK}"

fail=0
run() { # run <label> <dir> <command string>: as alissa, in a login shell
    local label="$1" dir="$2" cmd="$3"
    echo "--- ${label}: ${cmd}"
    if gosu alissa bash -lc "cd '${WORK}/${dir}' && ${cmd}"; then
        echo "ok   ${label}"
    else
        echo "FAIL ${label}" >&2
        fail=1
    fi
}

run "C (make)"            c      'make test'
run "C++ (cmake + ctest)" cpp    'cmake -S . -B build && cmake --build build && ctest --test-dir build --output-on-failure'
run "Go (go test)"        go     'go vet ./... && go test ./...'
run "Rust (cargo test)"   rust   'cargo test && cargo clippy -- -D warnings && cargo fmt --check'
run "Kotlin/Java (gradle test)" kotlin 'gradle test --no-daemon --console=plain'
run "Maven runs"          .      'mvn --version'

if [ "$fail" -ne 0 ]; then
    echo "polyglot smoke: FAILED" >&2
    exit 1
fi
echo "polyglot smoke: all languages built and tested"
