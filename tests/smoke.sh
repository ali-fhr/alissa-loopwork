#!/bin/bash
# Offline smoke test for the loopwork base image. Runs INSIDE the container
# (see tests/run.sh) and asserts the image contract the leaves build on:
# toolchain present, `alissa` user shaped right, git rewrites in place, claude
# first-run files seeded, workspace ENV skeleton set — plus the variant check
# (LOOPWORK_VARIANT: slim carries no compilers, polyglot carries all of them and
# a languages manifest that matches them).
# No network, no tokens. The polyglot build-and-test smoke is tests/polyglot/.
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
# `--version` alone cannot tell two snapshots of the alissa CLI apart (the
# published bundle keeps its version across rebuilds), so the bundle's sha256
# rides along — compare it with share.alissa.app/cli/cli.mjs.sha256 at release
# time. The installer drops the bundle at $HOME/.alissa/cli.mjs of the user
# that ran it (USER alissa in the Dockerfile).
ALISSA_BUNDLE=/home/alissa/.alissa/cli.mjs
echo "versions: claude-code $(ver claude @anthropic-ai/claude-code) | codex $(ver codex @openai/codex) | pi $(ver pi @mariozechner/pi-coding-agent) | alissa $(gosu alissa alissa --version 2>/dev/null || echo unknown) bundle-sha256 $(sha256sum "${ALISSA_BUNDLE}" 2>/dev/null | cut -c1-12 || echo unknown)"
# Release 0.2.3 exists to ship the paste lead-in (ali-fhr/studio.alissa.app
# #1590). Assert it OFFLINE, inside the built image: a cached install layer
# (the #6 blocker) or a stale share.alissa.app would fail here, in CI, before
# anything is published. Drop or replace when a later release supersedes it.
check "alissa CLI carries paste lead-in" grep -q pasteLeadIn "${ALISSA_BUNDLE}"

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

# --- variant: slim stays lean, polyglot carries its toolchains -------------------
# LOOPWORK_VARIANT is passed by tests/run.sh / the workflows (default: slim, so a
# bare run asserts the slim contract). Checked in the alissa user's LOGIN shell
# too — that is the PATH a tmux-spawned session sees (Debian's /etc/profile
# resets PATH, so ENV alone would not prove it).
TOOLCHAIN_BINS="gcc g++ cc c++ make cmake go gofmt rustup rustc cargo java javac gradle mvn sbt ruby gem bundle php composer dotnet R Rscript"
# The languages manifest Studio reads (polyglot only; slim ships none).
MANIFEST=/usr/local/share/alissa/languages.json
VARIANT="${LOOPWORK_VARIANT:-slim}"
echo "variant: ${VARIANT}"
case "$VARIANT" in
    slim)
        for b in $TOOLCHAIN_BINS; do
            check "slim has no ${b}"          sh -c "! command -v ${b}"
            check "slim has no ${b} (session)" gosu alissa bash -lc "! command -v ${b}"
        done
        check "slim has no /opt toolchains" sh -c '! test -e /opt/go && ! test -e /opt/rust && ! test -e /opt/java && ! test -e /opt/gradle && ! test -e /opt/maven && ! test -e /opt/ruby && ! test -e /opt/dotnet && ! test -e /opt/sbt'
        check "slim has no languages manifest" test ! -e "$MANIFEST"
        check "slim has no polyglot profile.d" test ! -e /etc/profile.d/loopwork-polyglot.sh
        check "slim has no sury apt source"    test ! -e /etc/apt/sources.list.d/sury-php.list
        check "slim has no CRAN apt source"    test ! -e /etc/apt/sources.list.d/cran-r.list
        check "slim has no sbt config/caches"  sh -c '! test -e /etc/sbt && ! test -e /home/alissa/.sbt && ! test -e /home/alissa/.cache/coursier'
        ;;
    polyglot)
        for b in $TOOLCHAIN_BINS clippy-driver rustfmt pkg-config; do
            check "polyglot has ${b} (session)" gosu alissa bash -lc "command -v ${b}"
        done
        check "rust owned by alissa"     sh -c 'test "$(stat -c %U /opt/rust/cargo /opt/rust/rustup | sort -u)" = "alissa"'
        check "JDK is 21"                gosu alissa bash -lc 'java -version 2>&1 | grep -q "version \"21\."'
        check "GOTOOLCHAIN=local (session)" gosu alissa bash -lc 'test "$(go env GOTOOLCHAIN)" = local'
        check "ruby owned by alissa"     sh -c 'test "$(stat -c %U /opt/ruby /opt/ruby/bin /opt/ruby/lib/ruby/gems | sort -u)" = "alissa"'
        check "gem dir writable by alissa" gosu alissa bash -lc 'test -w "$(ruby -e "print Gem.dir")"'
        check "ruby has bundler + minitest + rake" gosu alissa bash -lc 'ruby -rbundler -rminitest -rrake -ropenssl -rpsych -e 0'
        for ext in mbstring xml dom curl zip; do
            check "php has ext ${ext}"   gosu alissa bash -lc "php -m | grep -qix ${ext}"
        done
        check "dotnet owned by alissa"   sh -c 'test "$(stat -c %U /opt/dotnet /opt/dotnet/sdk | sort -u)" = "alissa"'
        check "dotnet SDK is an LTS 10.x" gosu alissa bash -lc 'dotnet --version | grep -q "^10\."'
        check "dotnet telemetry off (session)" gosu alissa bash -lc 'test "$DOTNET_CLI_TELEMETRY_OPTOUT" = 1 && test "$DOTNET_ROOT" = /opt/dotnet'
        check "sbt runs in the foreground"   grep -qx -- '--server' /etc/sbt/sbtopts
        check "sbt caches owned by alissa"   sh -c 'test "$(find /home/alissa/.sbt /home/alissa/.cache -not -user alissa | wc -l)" = 0'
        check "sbt boot pre-warmed"          sh -c 'ls -d /home/alissa/.sbt/boot/scala-*/org.scala-sbt/sbt/"$(gosu alissa bash -lc "sbt --script-version")"'
        check "R is 4.5+ (session)"          gosu alissa bash -lc 'Rscript -e "stopifnot(getRversion() >= \"4.5.0\")"'
        check "R has testthat + renv"        gosu alissa bash -lc 'Rscript -e "library(testthat); library(renv)"'
        check "R site library writable by alissa" gosu alissa bash -lc 'Rscript -e "stopifnot(file.access(.libPaths()[1], 2) == 0)"'
        check "R repo = pinned snapshot"     gosu alissa bash -lc 'Rscript -e "stopifnot(grepl(\"packagemanager.posit.co/cran/__linux__/\", getOption(\"repos\")[[\"CRAN\"]]))"'
        # The languages manifest: valid, exactly the expected ids, a version on
        # every entry, and each version equal to what the live tool reports.
        check "manifest is valid JSON"   jq -e . "$MANIFEST"
        check "manifest variant polyglot" sh -c "test \"\$(jq -r .variant '$MANIFEST')\" = polyglot"
        check "manifest lists every language" sh -c "test \"\$(jq -r '[.languages[].id] | sort | join(\" \")' '$MANIFEST')\" = 'c cpp csharp go java javascript kotlin php python r ruby rust scala'"
        check "manifest versions non-empty" jq -e '.languages | all(.version | type == "string" and length > 0)' "$MANIFEST"
        mver() { jq -r --arg id "$1" '.languages[] | select(.id == $id) | .version' "$MANIFEST"; }
        live() { gosu alissa bash -lc "$1" 2>/dev/null; }
        check "manifest python = live"   test "$(mver python)" = "$(live 'python3 -c "import platform; print(platform.python_version())"')"
        check "manifest c = live gcc"    test "$(mver c)"      = "$(live 'gcc -dumpfullversion')"
        check "manifest go = live"       test "$(mver go)"     = "$(live 'go env GOVERSION | sed s/^go//')"
        check "manifest rust = live"     test "$(mver rust)"   = "$(live 'rustc --version | cut -d" " -f2')"
        check "manifest ruby = live"     test "$(mver ruby)"   = "$(live 'ruby -e "print RUBY_VERSION"')"
        check "manifest php = live"      test "$(mver php)"    = "$(live 'php -r "echo PHP_VERSION;"')"
        check "manifest csharp = live dotnet" test "$(mver csharp)" = "$(live 'dotnet --version')"
        check "manifest scala = live sbt"  test "$(mver scala)"  = "$(live 'sbt --script-version')"
        check "manifest r = live"          test "$(mver r)"      = "$(live 'Rscript -e "cat(format(getRversion()))"')"
        # Informational: what this build carries (README records these).
        echo "toolchains:"
        for cmd in "gcc --version" "cmake --version" "go version" "rustc --version" \
                   "cargo --version" "java -version" "gradle --version" "mvn --version" \
                   "ruby --version" "bundle --version" "php --version" "composer --version" \
                   "dotnet --version" "sbt --script-version" "R --version"; do
            printf '  %-16s %s\n' "${cmd%% *}" "$(gosu alissa bash -lc "${cmd} 2>&1" | grep -m1 -E '[0-9]+\.[0-9]+' || echo unknown)"
        done
        echo "languages manifest:"
        jq -r '.languages[] | "  \(.id)\t\(.toolchain) \(.version)"' "$MANIFEST" 2>/dev/null || echo "  (unreadable)"
        ;;
    *)
        echo "FAIL unknown LOOPWORK_VARIANT=${VARIANT} (slim|polyglot)" >&2
        fail=1
        ;;
esac

if [ "$fail" -ne 0 ]; then
    echo "smoke: FAILED" >&2
    exit 1
fi
echo "smoke: all checks passed"
