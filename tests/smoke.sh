#!/bin/bash
# Offline smoke test for the loopwork base image. Runs INSIDE the container
# (see tests/run.sh) and asserts the image contract the leaves build on:
# toolchain present, `alissa` user shaped right, git rewrites in place, claude
# first-run files seeded, workspace ENV skeleton set. No network, no tokens.
set -euo pipefail

fail=0
check() { # check <label> <command...>
    local label="$1"; shift
    if "$@" > /dev/null 2>&1; then
        echo "ok   ${label}"
    else
        echo "FAIL ${label}: $*" >&2
        fail=1
    fi
}

# --- toolchain ---------------------------------------------------------------
check "python is 3.12"            sh -c 'python3 --version | grep -q "Python 3\.12\."'
check "node is v${NODE_MAJOR:-22}" sh -c 'node --version | grep -q "^v22\."'
check "gh present"                command -v gh
check "git present"               command -v git
check "tmux present"              command -v tmux
check "tini present"              test -x /usr/bin/tini
check "gosu present"              command -v gosu
check "jq present"                command -v jq
check "claude-code runs"          claude --version
check "codex runs"                codex --version
check "pi runs"                   pi --version
# Informational: the agent CLIs are unpinned, so print what this build actually
# snapshotted (the release notes in README.md record these numbers).
ver() { # ver <bin> <npm-package>: the CLI's own --version, else the installed npm version
    local out; out="$("$1" --version 2>&1 | head -1)"
    [ -n "$out" ] || out="$(npm ls -g --depth=0 2>/dev/null | grep -o "$2@[^ ]*")"
    printf '%s' "${out:-unknown}"
}
echo "versions: claude-code $(ver claude @anthropic-ai/claude-code) | codex $(ver codex @openai/codex) | pi $(ver pi @mariozechner/pi-coding-agent)"

# --- non-root user + workspace ----------------------------------------------
check "alissa uid is 1000"        sh -c 'test "$(id -u alissa)" = "1000"'
check "/workspace owned by alissa" sh -c 'test "$(stat -c %U /workspace)" = "alissa"'
check "alissa CLI on alissa PATH" gosu alissa sh -c 'command -v alissa'

# --- git system config ---------------------------------------------------------
check "both SSH->HTTPS rewrites"  sh -c 'test "$(git config --system --get-all url."https://github.com/".insteadOf | wc -l)" = "2"'
check "gh credential helper"      sh -c 'git config --system --get-all credential."https://github.com".helper | grep -q "gh auth git-credential"'
check "detachedHead advice off"   sh -c 'test "$(git config --system advice.detachedHead)" = "false"'

# --- claude first-run seeding --------------------------------------------------
check "onboarding pre-seeded"     grep -q hasCompletedOnboarding /home/alissa/.claude.json
check "bypass-prompt pre-seeded"  grep -q skipDangerousModePermissionPrompt /home/alissa/.claude/settings.json

# --- workspace ENV skeleton ----------------------------------------------------
check "ALISSA_WORKSPACE_ROOT"     sh -c 'test "$ALISSA_WORKSPACE_ROOT" = "/workspace"'
check "TMUX_TMPDIR"               sh -c 'test "$TMUX_TMPDIR" = "/home/alissa/.tmux" && test -d /home/alissa/.tmux'
check "CLAUDE_CONFIG_DIR"         sh -c 'test "$CLAUDE_CONFIG_DIR" = "/workspace/.claude-config"'

# --- entrypoint hook -----------------------------------------------------------
check "entrypoint stub in place"  test -x /usr/local/bin/entrypoint.sh
check "stub exits nonzero"        sh -c '! /usr/local/bin/entrypoint.sh'

if [ "$fail" -ne 0 ]; then
    echo "smoke: FAILED" >&2
    exit 1
fi
echo "smoke: all checks passed"
