# syntax=docker/dockerfile:1
# =============================================================================
# Alissa — loopwork base image
#
#   ghcr.io/ali-fhr/alissa-loopwork-base
#
# The shared runtime substrate for the loopwork daemon images that spawn claude
# agents through the alissa worker (today: alissa-github-develop-daemon and
# alissa-github-review-daemon). Those images were copy-paste siblings — ~85%
# identical infra layers, drifting independently. This image owns that shared
# 85%; each daemon repo keeps a thin leaf Dockerfile on top:
#
#   FROM ghcr.io/ali-fhr/alissa-loopwork-base:<pinned semver>   # never :latest
#   RUN pip install "alissa-tools-github-<loop>==<version>"
#   COPY entrypoint.sh /usr/local/bin/entrypoint.sh              # over the stub
#   COPY <helpers...> /usr/local/bin/
#   USER alissa
#   RUN git config --global user.name "<daemon identity>" \
#       && git config --global user.email "support@alissa.app"
#   USER root
#   ARG/ENV <the daemon's own knob block>
#
# What the base provides (and leaves must NOT re-do):
#   * python 3.12 + Node 22 + gh + git + tmux + tini + gosu (+ firewall tools)
#   * the agent CLIs the worker can spawn — claude-code (+ first-run
#     pre-seeding), codex, and pi — one image for all three
#   * the alissa CLI (worker, tmux queue, tasks) on the `alissa` user's PATH
#   * non-root `alissa` user (uid 1000) + /workspace volume mount point
#   * system-wide GitHub SSH→HTTPS rewrite with gh as credential helper
#   * the workspace ENV skeleton and the tini ENTRYPOINT hook
#
# What stays in the leaves (because it differs per daemon): the pip-installed
# daemon itself, the entrypoint + its helper scripts, the agents.yaml profile,
# the git author identity, and the whole ARG→ENV knob block (Railway pattern).
#
# The base is NOT runnable on its own: its entrypoint is a stub that exits 1
# with a pointer here. Secrets never enter this image — tokens (GH_TOKEN,
# ALISSA_API_TOKEN, CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY) are runtime
# env in the deployed leaf containers, exactly as before.
#
#   docker build -t alissa-loopwork-base .
#
# Versioning: bump the VERSION file (auto-tag + publish on merge, see
# .github/workflows/release.yml) or push a git tag vX.Y.Z by hand — either way
# the publish workflow ships :X.Y.Z, :X.Y and :X. Leaves pin an exact semver.
# =============================================================================

# Base is pinned to python 3.12 (matches the daemon repos' .python-version);
# Node 22 is layered on via NodeSource. The daemons need python >= 3.11; the
# alissa CLI and claude-code need Node >= 18 — both satisfied.
FROM python:3.12-slim-bookworm

# Node major version (must be >= 18 for the alissa CLI and claude-code).
ARG NODE_MAJOR=22

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# --- System dependencies ------------------------------------------------------
# git   : workers operate over git worktree hubs (dev workers commit/push)
# tmux  : the alissa worker manages tmux (ali-*) sessions
# gh     : the daemons shell out to `gh api`; also git's credential helper here
# tini   : PID 1 init — reaps the tmux/node/claude child fan-out
# gosu   : drop root -> alissa after the leaf entrypoint fixes the volume mount
# iptables/ipset : only used by the leaves' optional firewall init
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git tmux tini gosu \
        iptables ipset procps jq less; \
    # GitHub CLI apt repo
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    # Node.js via NodeSource
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; \
    apt-get install -y --no-install-recommends gh nodejs; \
    rm -rf /var/lib/apt/lists/*

# --- Agent CLIs (what the worker can spawn) -----------------------------------
# One image, three agents:
#   @anthropic-ai/claude-code        -> `claude` (the one the daemons drive today)
#   @openai/codex                    -> `codex`
#   @mariozechner/pi-coding-agent    -> `pi`    (NB: NOT @mariozechner/pi —
#                                       that package ships `pi-pods`, a
#                                       different tool)
# All unpinned on purpose: a base-image release snapshots whatever is current
# at build time, and leaves advance by bumping their base pin. That makes
# "bump the agents everywhere" a one-line change per leaf instead of a
# parallel npm edit per repo.
# Binaries only for codex/pi: their auth is runtime env (OPENAI_API_KEY /
# provider keys), and headless first-run seeding is deferred until a leaf
# actually wires them into a worker profile — only claude is pre-seeded below.
#
# --- Snapshot stamp: the unpinned CLI layers must never come from cache ------
# The agent CLIs (this layer) and the alissa CLI (`curl … | bash` further down)
# are installed UNPINNED on purpose: a patch release IS a re-snapshot of them
# (README "Releasing"). BuildKit's layer cache silently defeats that: with
# `cache-from: type=gha` and an unchanged python base digest, a VERSION-only
# release reuses the previous build's install layers byte-for-byte and ships
# the OLD bundles — caught on #6, whose trial build reported every install layer
# as CACHED and the 0.2.2-era alissa CLI as "0.3.0" (the new bundle says 0.3.0
# too). Both workflows pass SNAPSHOT_STAMP=<workflow run id>; a build arg busts
# the cache from its first USE, so everything from here down is rebuilt on every
# CI/release build while the apt/node layers above stay cached. Unset (a local
# `docker build`) = an ordinary cached dev build.
ARG SNAPSHOT_STAMP=unset
RUN echo "snapshot ${SNAPSHOT_STAMP}: agent CLIs" \
    && npm install -g \
        @anthropic-ai/claude-code \
        @openai/codex \
        @mariozechner/pi-coding-agent \
    && npm cache clean --force

# --- Non-root runtime user ----------------------------------------------------
# Agents run unattended with live tokens, and claude refuses
# --dangerously-skip-permissions as root, so the worker/daemon run as this user.
# The container still STARTS as root (see the USER root before ENTRYPOINT): the
# leaf entrypoint fixes the /workspace mount ownership, then drops to `alissa`
# via gosu. This is what makes a root-owned platform volume (e.g. Railway)
# writable.
RUN useradd --create-home --shell /bin/bash --uid 1000 alissa \
    && mkdir -p /workspace \
    && chown alissa:alissa /workspace

# --- git: force GitHub over HTTPS with the gh token (no SSH key in a container)
# `alissa code workspace add` clones over SSH by default (git@github.com:…), and
# the daemons' on_missing_hub:add path calls it WITHOUT --https — so there is no
# flag to flip. Rewrite every GitHub SSH URL to HTTPS system-wide and wire gh in
# as the credential helper (gh reads GH_TOKEN from the env). This makes clones
# (and dev workers' `git push`) authenticate for both the unprivileged daemon
# and any manual shell (root).
# NB: --add on the second insteadOf — a plain `git config` replaces the single
# value, so without it only the last rewrite survives (and git@github.com: is the
# form the alissa CLI actually emits).
# advice.detachedHead lives here at system level (it was per-user --global in
# the pre-base images); the per-daemon author identity stays in the leaves.
RUN git config --system url."https://github.com/".insteadOf "git@github.com:" \
    && git config --system --add url."https://github.com/".insteadOf "ssh://git@github.com/" \
    && git config --system credential."https://github.com".helper "" \
    && git config --system --add credential."https://github.com".helper "!gh auth git-credential" \
    && git config --system advice.detachedHead false

USER alissa
WORKDIR /home/alissa

# The alissa CLI installer is npm-free: it drops a `node cli.mjs` launcher into
# ~/.local/bin. Run it as the target user so it lands in the user's home.
ENV PATH="/home/alissa/.local/bin:${PATH}"
# SNAPSHOT_STAMP (declared above) is used here too, so this layer is never
# served from the previous release's cache — that is the whole point of a
# re-snapshot release.
RUN echo "snapshot ${SNAPSHOT_STAMP}: alissa CLI" \
    && curl -fsSL https://share.alissa.app/install | bash

# --- claude first-run gates: pre-seed so the TUI starts READY, no human ------
# A brand-new user hits claude's first-run dialogs (welcome/onboarding, theme
# picker, and the one-time --dangerously-skip-permissions "bypass mode" warning)
# and the worker hangs forever: "agent UI not ready — a first-run/trust dialog
# needs a human". These are the exact keys the working host carries, split across
# the two files claude reads:
#   ~/.claude.json          — user state: onboarding completed, warnings seen
#   ~/.claude/settings.json — settings: skip the bypass-mode prompt, theme, TUI
# skipDangerousModePermissionPrompt is the key the public docs omit; it is what
# lets `claude --dangerously-skip-permissions` come up without a keypress.
# Auth is still required and stays in the env (CLAUDE_CODE_OAUTH_TOKEN preferred
# — an interactive TUI would prompt to approve a bare ANTHROPIC_API_KEY).
RUN mkdir -p /home/alissa/.claude \
    && CLAUDE_VER="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" \
    && printf '{\n  "hasCompletedOnboarding": true,\n  "hasSeenAutoModeEntryWarning": true,\n  "lastOnboardingVersion": "%s"\n}\n' "${CLAUDE_VER:-2.1.215}" \
        > /home/alissa/.claude.json \
    && printf '{\n  "skipDangerousModePermissionPrompt": true,\n  "theme": "dark",\n  "tui": "fullscreen"\n}\n' \
        > /home/alissa/.claude/settings.json

# Workspace root that the daemons and workers operate over. Leaves mount a
# manifest here, or their entrypoints generate one. Fixed internal paths, not
# meant to be reconfigured.
#
# CLAUDE_CONFIG_DIR points claude's config — crucially its OAuth credential file
# `.credentials.json` — at a folder ON the /workspace volume, so a one-time
# `claude /login` survives restarts and auto-renews (a static CLAUDE_CODE_OAUTH_
# TOKEN expires and 401s). If you relocate the volume, move this with it.
ENV ALISSA_WORKSPACE_ROOT=/workspace \
    TMUX_TMPDIR=/home/alissa/.tmux \
    CLAUDE_CONFIG_DIR=/workspace/.claude-config
RUN mkdir -p /home/alissa/.tmux
WORKDIR /workspace

# The daemon consoles (alissa-devloop-ui / alissa-revloop-ui) listen here when
# a leaf enables them. EXPOSE is documentation/metadata only — it opens no port
# by itself; the leaf entrypoints bind 0.0.0.0:${PORT:-8080}.
EXPOSE 8080

# Start as root — two reasons: leaf builds layer their pip installs and COPYs
# without USER juggling, and at runtime the leaf entrypoint needs root to chown
# a root-owned platform volume before dropping to `alissa` via gosu.
USER root

# The ENTRYPOINT hook: tini as PID 1, then /usr/local/bin/entrypoint.sh — the
# fixed path every leaf COPYs its real entrypoint over. The base ships a stub
# there that exits 1 with a pointer, so running the base image bare fails loudly
# instead of half-starting something.
COPY entrypoint-stub.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
