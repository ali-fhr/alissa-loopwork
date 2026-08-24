# alissa-loopwork

Shared infrastructure for the **loopwork** daemon fleet — the autonomous coding
pipeline's containerized daemons (orcloop → devloop → revloop).

Today this repo owns one artifact: the **loopwork base image**.

```
ghcr.io/ali-fhr/alissa-loopwork-base
```

## Why a base image

The devloop and revloop daemon images (`alissa-github-develop-daemon` and
`alissa-github-review-daemon`, each at `docker/claude/Dockerfile`) were
copy-paste siblings: ~85% identical infrastructure layers that drifted
independently — the same incident got fixed twice in different shapes, and
version skew crept in between them. The base image owns that shared 85%; each
daemon repo keeps a thin **leaf** Dockerfile on top and advances infrastructure
by bumping one pinned base tag.

**In the base** (leaves must not re-do any of this):

- python 3.12 (`python:3.12-slim-bookworm`) + Node 22 (NodeSource)
- `git`, `tmux`, `gh`, `tini`, `gosu`, `jq` (+ `iptables`/`ipset` for the
  leaves' optional egress firewall)
- the **agent CLIs** the worker can spawn — one image for all three:
  - **claude-code** (`claude`) — the one the daemons drive today, with
    first-run gates pre-seeded (onboarding, bypass-mode prompt) so
    worker-spawned sessions start headless
  - **codex** (`@openai/codex`) and **pi** (`@mariozechner/pi-coding-agent` —
    *not* `@mariozechner/pi`, which ships a different tool) — binaries only for
    now: auth is runtime env (`OPENAI_API_KEY` / provider keys), and their
    headless first-run seeding is deferred until a leaf actually wires them
    into a worker profile (`agents.yaml`)
- the **alissa CLI** on the `alissa` user's PATH (worker, tmux queue, tasks)
- non-root **`alissa` user (uid 1000)** + `/workspace` mount point, with the
  start-as-root → entrypoint chowns the volume → gosu-drop contract
- system-wide GitHub **SSH→HTTPS rewrite** with `gh` as git's credential helper
- the workspace ENV skeleton: `ALISSA_WORKSPACE_ROOT=/workspace`,
  `TMUX_TMPDIR`, `CLAUDE_CONFIG_DIR=/workspace/.claude-config`
- the tini `ENTRYPOINT` hook at the fixed path `/usr/local/bin/entrypoint.sh`

**In the leaves** (because it differs per daemon): the pip-installed daemon
itself, the entrypoint + helper scripts (COPYed over the base's failing stub),
the `agents.yaml` profile, the git author identity, and the daemon's whole
ARG→ENV knob block (the Railway build-arg pattern).

The base is **not runnable** on its own: its entrypoint is a stub that exits 1
with a pointer here.

## The leaf contract

```dockerfile
FROM ghcr.io/ali-fhr/alissa-loopwork-base:0.1.0   # exact semver, never :latest

# 1. The daemon itself
RUN pip install "alissa-tools-github-<loop>==<version>"

# 2. Entrypoint (over the stub) + helpers
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY <helpers...>  /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# 3. Per-daemon user-level state
COPY --chown=alissa:alissa agents.yaml /home/alissa/.config/alissa/agents.yaml
USER alissa
RUN git config --global user.name  "<daemon-identity>" \
    && git config --global user.email "support@alissa.app"
USER root

# 4. The daemon's ARG→ENV knob block (kept last for layer-cache reasons)
ARG ...
ENV ...
# ENTRYPOINT is inherited from the base (tini + /usr/local/bin/entrypoint.sh).
```

Rules of the road:

- **Pin an exact semver.** A base bump is a deliberate, reviewable one-line PR
  in the leaf repo (Dependabot's `docker` ecosystem can automate these).
- **No secrets, ever** — in the base or in leaf build args. Tokens (`GH_TOKEN`,
  `ALISSA_API_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY`,
  `ALISSA_UI_PASSCODE`) are runtime env only; baked ARGs leak into
  `docker history`.
- The agent CLIs (claude-code, codex, pi) and the alissa CLI are deliberately
  **unpinned in the base Dockerfile**: each base *release* snapshots whatever
  is current, so "bump the agents everywhere" = release a base, bump the pin
  per leaf.

orcloop does **not** use this base: it is a pure poller with no Node, no
claude-code and no worker, and stays on `python-slim`.

## Building and testing locally

```sh
tests/run.sh            # docker build + offline smoke test (same as CI)
```

The smoke test (`tests/smoke.sh`) runs inside the container with no network and
no tokens: toolchain versions, user/workspace shape, git rewrites, claude
first-run seeding, ENV skeleton, entrypoint stub.

## Releasing

The release act is **bumping the `VERSION` file in your PR** (semver, no
leading `v`). On merge to `main`, the `release` workflow creates the matching
`vX.Y.Z` git tag and publishes `:X.Y.Z`, `:X.Y` and `:X` to GHCR (build +
smoke-test gated, `GITHUB_TOKEN` only). A PR that doesn't touch `VERSION`
releases nothing.

CI enforces the pairing on every PR (the `version-guard` job): touching an
image input (`Dockerfile`, `entrypoint-stub.sh`) without bumping `VERSION`
fails, as does setting `VERSION` to a value whose tag already exists (that PR
would merge and release nothing). The reverse stays legal — a VERSION-only
bump is how you re-snapshot the unpinned agent/alissa CLIs into a fresh
release.

Semver intent: **patch** = re-snapshot of the unpinned CLIs or non-contract
fixes; **minor** = additive (a new tool or agent CLI); **major** = a break in
the leaf contract above (entrypoint path, user, ENV skeleton, git config).

Manual fallback: `git tag vX.Y.Z && git push origin vX.Y.Z` still triggers the
`publish` workflow directly. The two routes never double-publish — the auto
path skips itself when the tag already exists. (Plumbing note: the auto path
*calls* publish rather than relying on its tag push, because `GITHUB_TOKEN`-
created tags don't trigger workflows.)

**One-time setup after the first publish:** GHCR packages default to
*private*. Flip `alissa-loopwork-base` to **public** in the org's package
settings (and ensure the org allows public packages) — the Railway services
build from their repos and pull the base anonymously; a private base would
break those builds (build-time pulls of private images aren't supported there).
Public is safe by construction: the image contains only public software and no
secrets.

## Roadmap

- Migrate `alissa-github-develop-daemon` and `alissa-github-review-daemon`
  onto the base (one task per repo).
- Extract the shared entrypoint logic (identity preflight / auth triage,
  agents.yaml model render, config generation, console sidecar launch) into a
  versioned lib shipped by this image (`/usr/local/lib/loopwork/`), shrinking
  each leaf entrypoint to wiring.
