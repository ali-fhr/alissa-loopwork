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
#   docker build -t alissa-loopwork-base .                          # slim (default)
#   docker build --target polyglot -t alissa-loopwork-base:polyglot .
#
# Two variants, one Dockerfile (see "Polyglot variant" at the bottom and the
# README): `slim` is the base described above and stays the default target;
# `polyglot` = slim + C/C++, Go, Rust, Java/Kotlin, Ruby, PHP and .NET toolchains
# (+ the languages manifest /usr/local/share/alissa/languages.json), published as
# the `-polyglot` tags. The polyglot stages add layers on top of slim and never
# change it.
#
# Versioning: bump the VERSION file (auto-tag + publish on merge, see
# .github/workflows/release.yml) or push a git tag vX.Y.Z by hand — either way
# the publish workflow ships :X.Y.Z, :X.Y and :X. Leaves pin an exact semver.
# =============================================================================

# --- Polyglot toolchain pins ----------------------------------------------------
# Used ONLY by the polyglot stages at the bottom of this file (global ARGs must
# precede the first FROM; an ARG a stage never re-declares does not touch it, so
# the slim stage is unaffected). Every download is verified against the sha
# pinned here — a bump changes the version AND its checksums together (README
# "Bumping a polyglot toolchain" has the commands that print them).
# Go — https://go.dev/dl/?mode=json (sha256 per linux archive)
ARG GO_VERSION=1.27.2
ARG GO_SHA256_AMD64=ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5
ARG GO_SHA256_ARM64=94f3e30b8e374bc285e7dadc11e0865726b9bc6e85b841ccceaabc0214c6b7c8
# Rust — rustup-init from static.rust-lang.org/rustup/archive/<ver>/<triple>/
# (+ .sha256); the toolchain itself is pinned by version and verified by rustup
# against the channel manifest's hashes.
ARG RUSTUP_VERSION=1.29.1
ARG RUSTUP_SHA256_AMD64=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
ARG RUSTUP_SHA256_ARM64=15f6e4ce9f583b929c996c91562bad6d4454f3281de858b02cdfdef615fac433
ARG RUST_VERSION=1.99.1
# Java — Eclipse Temurin JDK 21 LTS (api.adoptium.net, sha256 per tarball)
ARG TEMURIN_VERSION=21.0.12.1+1
ARG TEMURIN_SHA256_AMD64=ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94
ARG TEMURIN_SHA256_ARM64=23e37e026f12f3e706f18938ff611db3032d075b09d0879a25d06718c773e223
# Gradle (bin zip + .sha256) and Maven (bin tarball + .sha512); arch-independent
ARG GRADLE_VERSION=9.8.1
ARG GRADLE_SHA256=dce76f55f8e251a3a1f130eb120f30b3d271de2b76c9b0729d316b5a1b6dc01f
ARG MAVEN_VERSION=3.10.0
ARG MAVEN_SHA512=908b1501bfb420bf7c8affb855534a9c407fd6099367bfb9f2f2dcb8e9799102bffb84518cde74c679bd76870247c6528683abdd620581bffa90f95d92d175aa
# Ruby — source tarball from cache.ruby-lang.org (sha256 per release in
# /pub/ruby/index.txt), compiled in a throwaway stage; ships Bundler + the
# bundled gems (minitest, rake, …) of that release.
ARG RUBY_VERSION=4.0.7
ARG RUBY_SHA256=911ace20f90d068ca0e4dda6d0e4f0f81e52e52f2dd4f4004c721e253412e82d
# PHP — packages.sury.org, the Debian PHP maintainer's signed apt repo (bookworm
# itself stops at 8.2). The repo carries only each minor line's latest patch,
# so the pin is the MINOR line; the repo's signing keyring .deb is sha256-pinned.
ARG PHP_VERSION=8.5
ARG SURY_KEYRING_SHA256=7511384559c9ddf1d5ce5f60be429ae9d4e7d01d9480d6f1b7a30c0810cf8b60
# Composer — getcomposer.org/download/<ver>/composer.phar (+ .sha256sum)
ARG COMPOSER_VERSION=2.10.3
ARG COMPOSER_SHA256=7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6
# .NET SDK (LTS channel) — builds.dotnet.microsoft.com tarball, sha512 per arch
# from release-metadata/<channel>/releases.json
ARG DOTNET_SDK_VERSION=10.0.402
ARG DOTNET_SHA512_AMD64=1904a98dda2db34ba78ba3c4fb1b224455329af91c341d83547843c1839e112b04ae699ee92fa2449a8f62249196a938723078c0c60b9f65c88539d5687729c2
ARG DOTNET_SHA512_ARM64=db85ae85527251fbb1290720ac3bf324bb1d9eea74516ef291ed4bb1f8ff6ec63a17593367f49b456115e8b24ead6d0c2ece2801e501f36a6cd4444ed01a498f

# Base is pinned to python 3.12 (matches the daemon repos' .python-version);
# Node 22 is layered on via NodeSource. The daemons need python >= 3.11; the
# alissa CLI and claude-code need Node >= 18 — both satisfied.
# Stage `base` is the slim image's whole content: the `slim` target at the very
# end is `FROM base` with no instructions, so it is exactly these layers.
FROM python:3.12-slim-bookworm AS base

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

# =============================================================================
# Polyglot variant — `--target polyglot`, published as :X.Y.Z-polyglot (+ :X.Y-
# and :X-polyglot) next to the slim tags.
#
# A variant, not a fatter base: the base is shared by every fleet, and these
# toolchains add GBs that most leaves never use. A leaf opts in by pinning the
# -polyglot tag instead of the plain one; nothing else in the leaf contract
# changes (same user, entrypoint hook, ENV skeleton — this is slim + layers).
#
# Downloads happen in throwaway fetch stages that do not depend on `base`, so
# they stay cached across releases (only a pin bump refetches). The final stage
# sits below SNAPSHOT_STAMP (inherited from base), so its apt install and COPYs
# rerun on each CI/release build — cheap, the heavy downloads stay cached.
# =============================================================================
FROM python:3.12-slim-bookworm AS fetch
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl unzip; \
    rm -rf /var/lib/apt/lists/*
WORKDIR /tmp/fetch

FROM fetch AS go-fetch
ARG TARGETARCH
ARG GO_VERSION
ARG GO_SHA256_AMD64
ARG GO_SHA256_ARM64
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) sha="${GO_SHA256_AMD64}" ;; \
        arm64) sha="${GO_SHA256_ARM64}" ;; \
        *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH:-amd64}.tar.gz"; \
    echo "${sha}  go.tgz" | sha256sum -c -; \
    tar -C /opt -xzf go.tgz

FROM fetch AS jdk-fetch
ARG TARGETARCH
ARG TEMURIN_VERSION
ARG TEMURIN_SHA256_AMD64
ARG TEMURIN_SHA256_ARM64
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) arch=x64;     sha="${TEMURIN_SHA256_AMD64}" ;; \
        arm64) arch=aarch64; sha="${TEMURIN_SHA256_ARM64}" ;; \
        *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    tag="jdk-$(echo "${TEMURIN_VERSION}" | sed 's/+/%2B/')"; \
    file="OpenJDK21U-jdk_${arch}_linux_hotspot_$(echo "${TEMURIN_VERSION}" | tr + _).tar.gz"; \
    curl -fsSLo jdk.tgz "https://github.com/adoptium/temurin21-binaries/releases/download/${tag}/${file}"; \
    echo "${sha}  jdk.tgz" | sha256sum -c -; \
    mkdir -p /opt/java/temurin-21; \
    tar -C /opt/java/temurin-21 --strip-components=1 --exclude='*/lib/src.zip' -xzf jdk.tgz

FROM fetch AS gradle-fetch
ARG GRADLE_VERSION
ARG GRADLE_SHA256
RUN set -eux; \
    curl -fsSLo gradle.zip "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"; \
    echo "${GRADLE_SHA256}  gradle.zip" | sha256sum -c -; \
    unzip -q gradle.zip -d /opt; \
    mv "/opt/gradle-${GRADLE_VERSION}" /opt/gradle

FROM fetch AS maven-fetch
ARG MAVEN_VERSION
ARG MAVEN_SHA512
RUN set -eux; \
    curl -fsSLo maven.tgz "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz"; \
    echo "${MAVEN_SHA512}  maven.tgz" | sha512sum -c -; \
    mkdir -p /opt/maven; \
    tar -C /opt/maven --strip-components=1 -xzf maven.tgz

# Rust lives in /opt/rust (RUSTUP_HOME + CARGO_HOME), not in ~alissa or on the
# /workspace volume: a volume mounted over it would hide the toolchain, and a
# shared /opt keeps it out of per-user state. It is chowned to alissa (uid
# 1000) in the final stage so `rustup component add` / `cargo install` work for
# the unprivileged user.
FROM fetch AS rust-fetch
ARG TARGETARCH
ARG RUSTUP_VERSION
ARG RUSTUP_SHA256_AMD64
ARG RUSTUP_SHA256_ARM64
ARG RUST_VERSION
ENV RUSTUP_HOME=/opt/rust/rustup \
    CARGO_HOME=/opt/rust/cargo
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) triple=x86_64-unknown-linux-gnu;  sha="${RUSTUP_SHA256_AMD64}" ;; \
        arm64) triple=aarch64-unknown-linux-gnu; sha="${RUSTUP_SHA256_ARM64}" ;; \
        *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${triple}/rustup-init"; \
    echo "${sha}  rustup-init" | sha256sum -c -; \
    chmod +x rustup-init; \
    ./rustup-init -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_VERSION}" --component clippy,rustfmt; \
    find "${RUSTUP_HOME}/downloads" "${RUSTUP_HOME}/tmp" -mindepth 1 -delete

# Ruby is compiled here (same bookworm userland as the final stage, so it links
# against the same libssl3/libyaml/zlib/libffi the final stage installs) into
# /opt/ruby, which the final stage chowns to alissa: `gem install` and a plain
# `bundle install` then work without root, and the gems stay off the volume.
# Ruby's configure SKIPS an extension whose -dev package is missing instead of
# failing, hence the explicit require check of the ones that need system libs.
# No YJIT: it needs rustc at build time (a Rust pin bump would then rebuild Ruby).
FROM fetch AS ruby-build
ARG RUBY_VERSION
ARG RUBY_SHA256
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential libssl-dev libyaml-dev zlib1g-dev libffi-dev; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSLo ruby.tgz "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/ruby-${RUBY_VERSION}.tar.gz"; \
    echo "${RUBY_SHA256}  ruby.tgz" | sha256sum -c -; \
    tar -xzf ruby.tgz; \
    cd "ruby-${RUBY_VERSION}"; \
    ./configure --prefix=/opt/ruby --disable-install-doc; \
    make -j"$(nproc)"; \
    make install; \
    /opt/ruby/bin/ruby -ropenssl -rpsych -rzlib -rbundler \
        -e 'puts "ruby #{RUBY_VERSION}, bundler #{Bundler::VERSION}, #{OpenSSL::OPENSSL_LIBRARY_VERSION}"'

FROM fetch AS composer-fetch
ARG COMPOSER_VERSION
ARG COMPOSER_SHA256
RUN set -eux; \
    curl -fsSLo composer.phar "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar"; \
    echo "${COMPOSER_SHA256}  composer.phar" | sha256sum -c -; \
    install -m 0755 composer.phar /usr/local/bin/composer

FROM fetch AS dotnet-fetch
ARG TARGETARCH
ARG DOTNET_SDK_VERSION
ARG DOTNET_SHA512_AMD64
ARG DOTNET_SHA512_ARM64
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) arch=x64;   sha="${DOTNET_SHA512_AMD64}" ;; \
        arm64) arch=arm64; sha="${DOTNET_SHA512_ARM64}" ;; \
        *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo dotnet.tgz "https://builds.dotnet.microsoft.com/dotnet/Sdk/${DOTNET_SDK_VERSION}/dotnet-sdk-${DOTNET_SDK_VERSION}-linux-${arch}.tar.gz"; \
    echo "${sha}  dotnet.tgz" | sha512sum -c -; \
    mkdir -p /opt/dotnet; \
    tar -C /opt/dotnet -xzf dotnet.tgz

FROM base AS polyglot
# C / C++: gcc, g++, make (build-essential), cmake, pkg-config, gdb — from the
# bookworm archive, so their versions move with Debian point releases (pinned
# by the distro, not here).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential cmake pkg-config gdb; \
    rm -rf /var/lib/apt/lists/*
# PHP CLI + the common extensions (mbstring, xml — dom/xmlwriter/simplexml —,
# curl, zip) from sury's signed repo. Only the php keyring is taken out of the
# keyring .deb and bound to this one source (signed-by) — installing the .deb
# would drop it into trusted.gpg.d, i.e. trust it for every apt source. Also
# the runtime libs of the copied toolchains: libyaml (Ruby's psych) and libicu
# (.NET globalization); the rest (libssl3, zlib, libffi, libstdc++) is present.
ARG PHP_VERSION
ARG SURY_KEYRING_SHA256
RUN set -eux; \
    curl -fsSLo /tmp/sury-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb; \
    echo "${SURY_KEYRING_SHA256}  /tmp/sury-keyring.deb" | sha256sum -c -; \
    dpkg-deb --fsys-tarfile /tmp/sury-keyring.deb \
        | tar -xO ./usr/share/keyrings/deb.sury.org-php.gpg > /etc/apt/keyrings/sury-php.gpg; \
    rm /tmp/sury-keyring.deb; \
    chmod go+r /etc/apt/keyrings/sury-php.gpg; \
    . /etc/os-release; \
    echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${VERSION_CODENAME} main" \
        > /etc/apt/sources.list.d/sury-php.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "php${PHP_VERSION}-cli" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-xml" \
        "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" unzip \
        libyaml-0-2 libicu72; \
    rm -rf /var/lib/apt/lists/*
COPY --from=go-fetch     /opt/go     /opt/go
COPY --from=jdk-fetch    /opt/java   /opt/java
COPY --from=gradle-fetch /opt/gradle /opt/gradle
COPY --from=maven-fetch  /opt/maven  /opt/maven
COPY --from=rust-fetch   --chown=1000:1000 /opt/rust /opt/rust
COPY --from=ruby-build   --chown=1000:1000 /opt/ruby /opt/ruby
COPY --from=dotnet-fetch --chown=1000:1000 /opt/dotnet /opt/dotnet
COPY --from=composer-fetch /usr/local/bin/composer /usr/local/bin/composer

# ENV covers non-login processes (docker exec, gosu, the daemon itself). Login
# shells — what tmux starts for worker sessions — run Debian's /etc/profile,
# which RESETS PATH; the profile.d drop-in puts the toolchains back after it.
# GOTOOLCHAIN=local: a go.mod asking for a newer Go fails loudly instead of
# silently downloading a toolchain at test time. The DOTNET_* knobs keep the
# SDK quiet for unattended sessions: no telemetry, no first-run banner, no
# dev-cert generation. Per-user caches (NuGet's ~/.nuget/packages, Composer's
# ~/.cache/composer, Bundler's ~/.bundle) live in the alissa home, off the
# /workspace volume.
ENV JAVA_HOME=/opt/java/temurin-21 \
    GRADLE_HOME=/opt/gradle \
    MAVEN_HOME=/opt/maven \
    RUSTUP_HOME=/opt/rust/rustup \
    CARGO_HOME=/opt/rust/cargo \
    GOTOOLCHAIN=local \
    DOTNET_ROOT=/opt/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_GENERATE_ASPNET_CERTIFICATE=false \
    PATH="/opt/rust/cargo/bin:/opt/go/bin:/opt/java/temurin-21/bin:/opt/gradle/bin:/opt/maven/bin:/opt/ruby/bin:/opt/dotnet:${PATH}"
COPY <<'EOF' /etc/profile.d/loopwork-polyglot.sh
# loopwork polyglot variant: toolchains on PATH for login shells (tmux sessions).
export JAVA_HOME=/opt/java/temurin-21
export GRADLE_HOME=/opt/gradle
export MAVEN_HOME=/opt/maven
export RUSTUP_HOME=/opt/rust/rustup
export CARGO_HOME=/opt/rust/cargo
export GOTOOLCHAIN=local
export DOTNET_ROOT=/opt/dotnet
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export DOTNET_GENERATE_ASPNET_CERTIFICATE=false
case ":$PATH:" in
    *:/opt/go/bin:*) ;;
    *) PATH="/opt/rust/cargo/bin:/opt/go/bin:/opt/java/temurin-21/bin:/opt/gradle/bin:/opt/maven/bin:/opt/ruby/bin:/opt/dotnet:$PATH" ;;
esac
export PATH
EOF

# --- Languages manifest ----------------------------------------------------------
# /usr/local/share/alissa/languages.json: which languages this image covers and
# with which toolchain versions — read by Studio's boundary, so a new language
# here needs no code change there. Every version is read from the INSTALLED
# tool at build time (not from the pins above), so the manifest cannot drift
# from the image; a tool that does not answer fails the build. The slim image
# ships no manifest (its content stays exactly the base stage): absent manifest
# = slim = python + node only. Schema: README "The languages manifest".
# HOME is a throwaway dir so probing gradle/dotnet/composer leaves no root state.
RUN <<'EOF'
set -eu
export HOME=/tmp/manifest-home
mkdir -p /tmp/manifest-home /usr/local/share/alissa
req() { # req <name> <value>: print value, fail the build if empty
    [ -n "$2" ] || { echo "languages manifest: no version for $1" >&2; exit 1; }
    printf '%s' "$2"
}
python="$(req python "$(python3 -c 'import platform; print(platform.python_version())')")"
pip="$(req pip "$(python3 -m pip --version | awk '{print $2}')")"
node="$(req node "$(node -p process.versions.node)")"
npm="$(req npm "$(npm --version)")"
gcc="$(req gcc "$(gcc -dumpfullversion)")"
gxx="$(req g++ "$(g++ -dumpfullversion)")"
make="$(req make "$(make --version | sed -n '1s/^GNU Make //p')")"
cmake="$(req cmake "$(cmake --version | sed -n '1s/^cmake version //p')")"
go="$(req go "$(go env GOVERSION | sed 's/^go//')")"
rustc="$(req rustc "$(rustc --version | awk '{print $2}')")"
cargo="$(req cargo "$(cargo --version | awk '{print $2}')")"
rustup="$(req rustup "$(rustup --version 2>/dev/null | awk 'NR==1{print $2}')")"
java="$(req java "$(java -version 2>&1 | sed -n '1s/.*version "\([^"]*\)".*/\1/p')")"
gradle="$(req gradle "$(GRADLE_USER_HOME=/tmp/manifest-home/gradle gradle --version --no-daemon | sed -n 's/^Gradle //p')")"
maven="$(req maven "$(mvn --version | awk 'NR==1{print $3}')")"
ruby="$(req ruby "$(ruby -e 'print RUBY_VERSION')")"
gem="$(req gem "$(gem --version)")"
bundler="$(req bundler "$(ruby -rbundler -e 'print Bundler::VERSION')")"
php="$(req php "$(php -r 'echo PHP_VERSION;')")"
composer="$(req composer "$(COMPOSER_ALLOW_SUPERUSER=1 composer --version --no-ansi 2>/dev/null | sed -n 's/^Composer version \([^ ]*\).*/\1/p')")"
phpext="$(php -r 'echo json_encode(array_map("strtolower", get_loaded_extensions()));')"
dotnet="$(req dotnet-sdk "$(dotnet --version)")"
dotnetrt="$(req dotnet-runtime "$(dotnet --list-runtimes | awk '$1=="Microsoft.NETCore.App"{v=$2} END{print v}')")"
jq -n \
    --arg python "$python" --arg pip "$pip" --arg node "$node" --arg npm "$npm" \
    --arg gcc "$gcc" --arg gxx "$gxx" --arg make "$make" --arg cmake "$cmake" \
    --arg go "$go" --arg rustc "$rustc" --arg cargo "$cargo" --arg rustup "$rustup" \
    --arg java "$java" --arg gradle "$gradle" --arg maven "$maven" \
    --arg ruby "$ruby" --arg gem "$gem" --arg bundler "$bundler" \
    --arg php "$php" --arg composer "$composer" --argjson phpext "$phpext" \
    --arg dotnet "$dotnet" --arg dotnetrt "$dotnetrt" \
    '{
      schema: 1,
      image: "ghcr.io/ali-fhr/alissa-loopwork-base",
      variant: "polyglot",
      languages: [
        {id: "python", name: "Python", toolchain: "cpython", version: $python,
         tools: {python: $python, pip: $pip}},
        {id: "javascript", name: "JavaScript (Node.js)", toolchain: "node", version: $node,
         tools: {node: $node, npm: $npm}},
        {id: "c", name: "C", toolchain: "gcc", version: $gcc,
         tools: {gcc: $gcc, make: $make, cmake: $cmake}},
        {id: "cpp", name: "C++", toolchain: "g++", version: $gxx,
         tools: {"g++": $gxx, make: $make, cmake: $cmake}},
        {id: "go", name: "Go", toolchain: "go", version: $go,
         tools: {go: $go}},
        {id: "rust", name: "Rust", toolchain: "rustc", version: $rustc,
         tools: {rustc: $rustc, cargo: $cargo, rustup: $rustup}},
        {id: "java", name: "Java", toolchain: "temurin-jdk", version: $java,
         tools: {jdk: $java, gradle: $gradle, maven: $maven}},
        {id: "kotlin", name: "Kotlin", toolchain: "gradle", version: $gradle,
         tools: {gradle: $gradle, jdk: $java},
         note: "no kotlinc in the image: the Kotlin compiler is resolved per project by the Kotlin Gradle plugin"},
        {id: "ruby", name: "Ruby", toolchain: "ruby", version: $ruby,
         tools: {ruby: $ruby, gem: $gem, bundler: $bundler}},
        {id: "php", name: "PHP", toolchain: "php-cli", version: $php,
         tools: {php: $php, composer: $composer}, extensions: $phpext},
        {id: "csharp", name: "C#", toolchain: "dotnet-sdk", version: $dotnet,
         tools: {"dotnet-sdk": $dotnet, "dotnet-runtime": $dotnetrt}}
      ]
    }' > /usr/local/share/alissa/languages.json
chmod 0644 /usr/local/share/alissa/languages.json
rm -rf /tmp/manifest-home /root/.m2 /root/.gradle /root/.dotnet /root/.nuget
cat /usr/local/share/alissa/languages.json
EOF

# =============================================================================
# Default target: the slim base, exactly the `base` stage (no instructions here
# on purpose). Keeping it LAST keeps a plain `docker build .` = slim.
# =============================================================================
FROM base AS slim
