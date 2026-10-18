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

## The polyglot variant

```
ghcr.io/ali-fhr/alissa-loopwork-base:X.Y.Z-polyglot     (+ :X.Y-polyglot, :X-polyglot)
```

The same base **plus compilers**, so sessions can build and test C, C++, Go,
Rust, Java/Kotlin, Scala (incl. Apache Spark jobs in local mode), Ruby, PHP,
.NET (C#) and R before opening a PR (and the reviewer can re-run them).
It is the `polyglot` target of the same `Dockerfile` — slim + toolchain
layers, nothing in the slim layers changes — and is published by the same
release, smoke-gated, next to the slim tags.

**Why a variant and not a fatter base:** the base is shared by every fleet
(ours and clients'), and the toolchains add ~1.7 GB (≈ 0.75 GB compressed)
that most leaves never use. Paying that on every pull, every fleet, for a capability only some
fleets need is the wrong default; the variant makes it opt-in per fleet.
(Those figures are 0.3.0's; the measured size of the current variant is in
the table below.)

| | slim (default) | polyglot |
|---|---|---|
| everything in "In the base" above | ✓ | ✓ |
| C / C++: `gcc`, `g++`, `make` (build-essential), `cmake`, `pkg-config`, `gdb` | — | Debian bookworm packages |
| Go | — | **1.27.2** (go.dev tarball, sha256-pinned) |
| Rust: `rustup`, `rustc`, `cargo`, `clippy`, `rustfmt` | — | **1.99.1** via rustup 1.29.1 (rustup-init sha256-pinned) |
| Java: Eclipse Temurin JDK 21 LTS | — | **21.0.12.1+1** (sha256-pinned) |
| Gradle (Kotlin builds through Gradle's Kotlin plugin) | — | **9.8.1** (sha256-pinned) |
| Maven | — | **3.10.0** (sha512-pinned) |
| Ruby (+ Bundler, RubyGems, the bundled minitest/rake) | — | **4.0.7**, compiled from the sha256-pinned source tarball; Bundler 4.0.20 |
| PHP CLI + mbstring, xml (dom, xmlwriter, …), curl, zip | — | **8.5** line from packages.sury.org (signed apt repo; keyring sha256-pinned) |
| Composer | — | **2.10.3** (sha256-pinned) |
| .NET SDK (C#), LTS channel | — | **10.0.402** (runtime 10.0.13; sha512-pinned) |
| Scala: `sbt` on the JDK above (Scala 2.13 / 3 resolved per project) | — | **sbt 2.0.10** (sha256-pinned), its boot + coursier cache pre-warmed in the alissa home |
| Apache Spark (local mode) | — | per project via sbt — smoke-tested with **Spark 4.2.0** on Scala 2.13.18 |
| R: `R`, `Rscript` (r-base, r-base-dev) | — | **4.5.3** from CRAN's Debian repo (`4.5.3-1~bookwormcran.0`; key fingerprint-pinned) |
| R packages `testthat`, `renv` | — | **3.3.2**, **1.3.1** — Posit Package Manager snapshot 2026-10-15 |
| languages manifest `/usr/local/share/alissa/languages.json` | — (absent) | ✓ (see below) |
| size, linux/amd64 (compressed ≈ / uncompressed) | ≈ 464 MB / 1.3 GB | 0.3.0: ≈ 1.2 GB / 3.0 GB · 0.4.0: ≈ 1.5 GB / 3.8 GB · 0.5.0: **SIZE_TBD** |

Sizes are CI-measured (compressed ≈ gzip of `docker save`, from CI's "Image
sizes" step); the exact registry numbers for every release are in its GitHub
release notes (`publish.yml` writes them).

Layout, all usable by the unprivileged `alissa` user:

- toolchains under `/opt` (`/opt/go`, `/opt/java/temurin-21`, `/opt/gradle`,
  `/opt/maven`, `/opt/rust`, `/opt/ruby`, `/opt/dotnet`) — off the
  `/workspace` volume, so a mount never hides them; PHP is the Debian-layout
  package (`/usr/bin/php`), Composer is `/usr/local/bin/composer`;
- Rust: `RUSTUP_HOME=/opt/rust/rustup`, `CARGO_HOME=/opt/rust/cargo`, owned by
  `alissa` so `rustup component add` / `cargo install` work without root;
- Ruby: `/opt/ruby` is owned by `alissa`, so `gem install` and a plain
  `bundle install` write the image's gem dir without root (no YJIT: it would
  need rustc at Ruby's build time);
- .NET: `DOTNET_ROOT=/opt/dotnet`, owned by `alissa` (so `dotnet workload`
  works without root), with `DOTNET_CLI_TELEMETRY_OPTOUT=1`, `DOTNET_NOLOGO=1`
  and `DOTNET_GENERATE_ASPNET_CERTIFICATE=false` for unattended sessions;
- Scala: the sbt runner is `/opt/sbt`, and `/etc/sbt/sbtopts` makes
  `--server` the default — sbt 2.x otherwise runs its thin client and leaves
  a background sbt server JVM behind every call, an orphan in an unattended
  seat (`sbt --client` still opts in). The pinned sbt's boot dir
  (`~/.sbt/boot`) and the coursier cache of sbt's own artifacts
  (`~/.cache/coursier`) are pre-warmed into the alissa home (≈ 200 MB), so a
  project on sbt 2.0.10 starts without fetching sbt itself; its Scala
  compiler and libraries — Spark's ≈ 300 MB of jars included — are fetched
  per project at first build. There is no `scalac`/`spark-submit` in the
  image: Spark runs in-process in local mode (`master("local[*]")`), the
  JVM needing Spark's `--add-opens` module flags (see
  `tests/polyglot/spark/build.sbt`);
- R: the Debian-layout r-base (`/usr/bin/R`, `/usr/bin/Rscript`); the site
  library `/usr/local/lib/R/site-library` (testthat, renv) is owned by
  `alissa`, so `install.packages()` and `renv::restore()` work without root,
  and `/etc/R/Rprofile.site` makes the dated Posit Package Manager snapshot
  the default repo (bookworm binaries — no compile for most packages;
  r-base-dev is there for the ones that must build from source);
- on `PATH` both via image `ENV` (daemon, `docker exec`, gosu) **and**
  `/etc/profile.d/loopwork-polyglot.sh` — tmux-spawned sessions are login
  shells, and Debian's `/etc/profile` resets `PATH`;
- `GOTOOLCHAIN=local`: a `go.mod` asking for a newer Go fails loudly rather
  than downloading a toolchain mid-session. Per-user caches (`~/go`,
  `~/.cache/go-build`, `~/.gradle`, `~/.m2`, `~/.bundle`, `~/.cache/composer`,
  `~/.nuget/packages`, `~/.dotnet`, `~/.sbt`, `~/.cache/coursier`,
  `~/.cache/R/renv`) live in the alissa home — not on the `/workspace` volume,
  so a mount neither hides nor carries them (and the pre-warmed sbt caches
  are image content).

**Opting in** (a leaf, i.e. a fleet): change the base pin to the `-polyglot`
tag of the same version — nothing else in the leaf contract changes:

```dockerfile
FROM ghcr.io/ali-fhr/alissa-loopwork-base:0.5.0-polyglot   # was :0.5.0
```

Adopting the variant is an **operator rollout decision**, made per fleet; the
release that introduced it (0.3.0), the one that added Ruby, PHP and .NET
(0.4.0) and the one that added Scala/Spark and R (0.5.0) rolled no fleet. A fleet already on `-polyglot` picks up the new
languages only when its leaf bumps the pin.

### The languages manifest

The polyglot image ships `/usr/local/share/alissa/languages.json`, so Studio's
boundary can read which languages a fleet's image covers without a code change
per language. It is generated at **build time from the installed tools** (not
from the pins), so it cannot drift from the image, and the contract smoke
cross-checks it against the live tools. The slim image ships **no** manifest —
its content stays exactly the base — so *absent* means slim: Python and
Node.js only.

```json
{
  "schema": 1,
  "image": "ghcr.io/ali-fhr/alissa-loopwork-base",
  "variant": "polyglot",
  "languages": [
    {"id": "ruby", "name": "Ruby", "toolchain": "ruby", "version": "4.0.7",
     "tools": {"ruby": "4.0.7", "gem": "…", "bundler": "4.0.20"}},
    {"id": "php", "name": "PHP", "toolchain": "php-cli", "version": "8.5.…",
     "tools": {"php": "8.5.…", "composer": "2.10.3"}, "extensions": ["core", "…"]},
    …
  ]
}
```

- `languages[].id` is the stable key: `python`, `javascript`, `c`, `cpp`,
  `go`, `rust`, `java`, `kotlin`, `scala`, `ruby`, `php`, `csharp`, `r`.
- `version` is the primary toolchain's version (`toolchain` names it); `tools`
  maps every tool that serves the language to its version. `kotlin` has no
  `kotlinc` in the image — the compiler comes per project from the Kotlin
  Gradle plugin — so its toolchain is Gradle (see its `note`). Likewise
  `scala`'s toolchain is sbt (`tools`: `sbt`, `jdk`): sbt resolves each
  project's Scala and libraries, Spark included. `r` also carries
  `packages` (`testthat`, `renv` versions).
- `schema` bumps only on an incompatible change; new languages and new keys
  are additive. Each release's notes carry the full manifest.

```sh
docker run --rm --entrypoint cat ghcr.io/ali-fhr/alissa-loopwork-base:0.5.0-polyglot \
    /usr/local/share/alissa/languages.json
```

### Bumping a polyglot toolchain

All pins are the `ARG` block at the top of the `Dockerfile`; change a version
**and** its checksum(s) together, then bump `VERSION` (CI's version guard
requires it — the Dockerfile is an image input). Where to get each value:

```sh
# Go: version + sha256 per arch
curl -fsS 'https://go.dev/dl/?mode=json' | jq -r '.[0] | .version, (.files[] | select(.os=="linux" and .kind=="archive" and (.arch=="amd64" or .arch=="arm64")) | "\(.arch) \(.sha256)")'
# Rust toolchain version (RUST_VERSION) and rustup-init (RUSTUP_VERSION + sha256)
curl -fsS https://static.rust-lang.org/dist/channel-rust-stable.toml | grep -A1 '^\[pkg.rust\]'
curl -fsS https://static.rust-lang.org/rustup/release-stable.toml
curl -fsS https://static.rust-lang.org/rustup/archive/<ver>/{x86_64,aarch64}-unknown-linux-gnu/rustup-init.sha256
# Temurin 21: release name + sha256 per arch
curl -fsS 'https://api.adoptium.net/v3/assets/latest/21/hotspot?image_type=jdk&os=linux&vendor=eclipse' | jq -r '.[] | select(.binary.architecture=="x64" or .binary.architecture=="aarch64") | "\(.binary.architecture) \(.release_name) \(.binary.package.checksum)"'
# Gradle
curl -fsS https://services.gradle.org/versions/current | jq -r .version
curl -fsSL https://services.gradle.org/distributions/gradle-<ver>-bin.zip.sha256
# Maven
curl -fsS https://archive.apache.org/dist/maven/maven-3/<ver>/binaries/apache-maven-<ver>-bin.tar.gz.sha512
# Ruby: version + sha256 of the .tar.gz (columns: name, url, sha1, sha256, sha512)
curl -fsS https://cache.ruby-lang.org/pub/ruby/index.txt | grep -E '^ruby-[0-9.]+\s.*\.tar\.gz' | tail -3
# PHP: the minor lines sury carries for bookworm; keyring .deb sha256
curl -fsS https://packages.sury.org/php/dists/bookworm/main/binary-amd64/Packages.gz | gunzip | grep -E '^Package: php8\.[0-9]+-cli$'
curl -fsSL https://packages.sury.org/debsuryorg-archive-keyring.deb | sha256sum
# Composer: latest stable + its sha256
curl -fsS https://getcomposer.org/versions | jq -r '.stable[0].version'
curl -fsSL https://getcomposer.org/download/<ver>/composer.phar.sha256sum
# .NET: the LTS channel's latest SDK + sha512 per arch
curl -fsS https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json | jq -r '.["releases-index"][] | select(.["release-type"]=="lts" and .["support-phase"]=="active") | "\(.["channel-version"]) \(.["latest-sdk"])"'
curl -fsS https://builds.dotnet.microsoft.com/dotnet/release-metadata/<channel>/releases.json | jq -r '.releases[] | select(.sdk.version=="<sdk>") | .sdk.files[] | select((.rid=="linux-x64" or .rid=="linux-arm64") and (.name|endswith(".tar.gz"))) | "\(.rid) \(.hash)"'
# sbt: latest non-prerelease runner + its sha256
curl -fsS 'https://api.github.com/repos/sbt/sbt/releases?per_page=10' | jq -r '[.[] | select(.prerelease|not)][0].tag_name'
curl -fsSL https://github.com/sbt/sbt/releases/download/v<ver>/sbt-<ver>.tgz.sha256
# R: the r-base version CRAN carries for bookworm (R_VERSION is the full Debian version)
curl -fsSL https://cloud.r-project.org/bin/linux/debian/bookworm-cran40/Packages | awk '/^Package: r-base-core$/{p=1} p&&/^Version:/{print $2; exit}'
# testthat / renv in a PPM snapshot (CRAN_SNAPSHOT is the dated URL)
curl -fsS https://packagemanager.posit.co/cran/__linux__/bookworm/<YYYY-MM-DD>/src/contrib/PACKAGES | awk '/^Package: (testthat|renv)$/{p=$2} p&&/^Version:/{print p, $2; p=""}'
```

`TEMURIN_VERSION` is the release name without the `jdk-` prefix (e.g.
`21.0.12.1+1`). The C/C++ tools come from the Debian archive and move with
the base OS. If you bump Gradle, check the Kotlin plugin version in
`tests/polyglot/kotlin/build.gradle.kts` still supports it. sury keeps only
the latest patch of each PHP minor line, so the PHP patch moves with every
build; `PHP_VERSION` pins the minor. A new .NET LTS channel also needs
`tests/polyglot/dotnet/` moved to its `net<N>.0` target framework (and the
contract smoke's `10.x` check). If a newer sury keyring is published, the
build fails on its sha256 — re-check the key and re-pin. CRAN's Debian repo
lists only the current r-base build, so the exact `R_VERSION` pin fails the
build loudly once CRAN replaces it (bookworm-cran40 has been frozen at 4.5.3
since 2026-03) — re-pin from the command above. When bumping sbt, bump
`sbt.version` in `tests/polyglot/{scala,spark}/project/build.properties` with
it (the pre-warmed boot only serves that version); Spark's Scala version
(`tests/polyglot/spark/build.sbt`) follows Spark's own `scala.version`.

## Building and testing locally

```sh
tests/run.sh            # slim: docker build + offline smoke test (same as CI)
tests/run.sh polyglot   # polyglot: build + contract smoke + per-language smoke
tests/run.sh all        # both
```

The smoke test (`tests/smoke.sh`) runs inside the container with no network and
no tokens: toolchain versions, user/workspace shape, git rewrites, claude
first-run seeding, ENV skeleton, entrypoint stub — and the variant check: on
slim it asserts **none** of `gcc`/`g++`/`make`/`cmake`/`go`/`cargo`/`rustc`/
`java`/`gradle`/`mvn`/`sbt`/`R` exist (so the base can't bloat by accident), on polyglot
that all of them are on the `alissa` session PATH and that the languages
manifest lists them with the versions the live tools report. The polyglot
variant also runs `tests/polyglot/smoke.sh`, which compiles and tests a tiny
sample project per language as `alissa` (C via make, C++ via cmake + ctest,
`go test`, `cargo test`, `gradle test`, `bundle exec rake test` (minitest),
`composer install` + `phpunit`, `dotnet test` (xunit), `sbt testFull` (ScalaTest,
Scala 3) and a Spark local-mode word count (`sbt testFull`, Scala 2.13), and
`testthat::test_dir` via `Rscript`); see
`tests/polyglot/README.md`.

CI also asserts that the polyglot variant leaves slim **byte-identical**:
polyglot's layer chain must start with slim's (CI, publish, and
`tests/run.sh all`), and on every PR the branch's slim must have the same layer
diff IDs and runtime config as the base branch's slim built in the same builder
with the same snapshot stamp. A PR that changes slim on purpose carries the
`slim-change` label to skip that second check.

## Releasing

The release act is **bumping the `VERSION` file in your PR** (semver, no
leading `v`). On merge to `main`, the `release` workflow creates the matching
`vX.Y.Z` git tag and publishes `:X.Y.Z`, `:X.Y` and `:X` — and the same three
with a `-polyglot` suffix — to GHCR (build + smoke-test gated, `GITHUB_TOKEN`
only), then writes the `vX.Y.Z` GitHub release notes with each variant's
compressed size. A PR that doesn't touch `VERSION`
releases nothing.

CI enforces the pairing on every PR (the `version-guard` job): touching an
image input (`Dockerfile`, `entrypoint-stub.sh`) without bumping `VERSION`
fails, as does setting `VERSION` to a value whose tag already exists (that PR
would merge and release nothing). The reverse stays legal — a VERSION-only
bump is how you re-snapshot the unpinned agent/alissa CLIs into a fresh
release.

The unpinned CLI layers are rebuilt on **every** CI and release build: both
workflows pass `SNAPSHOT_STAMP=<run id>` as a build arg that the Dockerfile
uses right before the `npm install -g` and `curl … | bash` steps, so BuildKit's
GHA cache can never hand a release the previous build's install layers (which
it did on the 0.2.3 trial build — every install layer `CACHED`, old bundle
inside). The apt/node layers above the stamp stay cached. The smoke test prints
the alissa bundle's sha256 next to its version for the same reason: `--version`
alone cannot tell two snapshots apart.

Semver intent: **patch** = re-snapshot of the unpinned CLIs or non-contract
fixes; **minor** = additive (a new tool or agent CLI); **major** = a break in
the leaf contract above (entrypoint path, user, ENV skeleton, git config).

Manual fallback: `git tag vX.Y.Z && git push origin vX.Y.Z` still triggers the
`publish` workflow directly. The two routes never double-publish — the auto
path skips itself when the tag already exists. (Plumbing note: the auto path
*calls* publish rather than relying on its tag push, because `GITHUB_TOKEN`-
created tags don't trigger workflows.)

### Release history

Each entry records what the release's build snapshotted (the agent CLIs are
unpinned, so the number is only known once the image is built — CI's smoke
step prints them; see `tests/smoke.sh`).

- **0.5.0** — the polyglot variant gains **Scala** via **sbt 2.0.10** (JDK 21
  reused; sbt boot + coursier cache pre-warmed in the alissa home, ≈ 200 MB)
  — proven by a ScalaTest build (Scala 3.10.0) and an **Apache Spark 4.2.0
  local-mode** word count (Scala 2.13.18) — and **R 4.5.3** (CRAN's Debian
  repo; r-base + r-base-dev) with **testthat 3.3.2** and **renv 1.3.1** (PPM
  snapshot 2026-10-15), proven by a testthat run via `Rscript`; both are in
  the languages manifest (`scala`, `r`). Polyglot size (linux/amd64,
  CI-measured): SIZE_TBD_HISTORY. Slim's content is unchanged (CI asserts it
  byte-identical to the base branch's slim); agent CLIs re-snapshotted as of
  the build date. No fleet rolled.
- **0.4.0** — the polyglot variant gains **Ruby 4.0.7** (+ Bundler 4.0.20),
  **PHP 8.5** (sury; mbstring, xml, curl, zip) + **Composer 2.10.3**, and the
  **.NET SDK 10.0.402** (LTS), each proven by a build-and-test smoke (minitest,
  PHPUnit, xunit) as `alissa`; plus the **languages manifest**
  `/usr/local/share/alissa/languages.json` covering every polyglot language.
  Polyglot size (linux/amd64, CI-measured): ≈ 1.5 GB compressed / 3.8 GB uncompressed (0.3.0: ≈ 1.2 GB / 3.0 GB; slim unchanged at ≈ 464 MB / 1.3 GB). Slim's
  content is unchanged (CI asserts it byte-identical to the base branch's slim); agent CLIs
  re-snapshotted as of the build date. No fleet rolled.
- **0.3.0** — adds the **polyglot variant** (`:0.3.0-polyglot`, see "The
  polyglot variant"): C/C++ (build-essential, cmake, pkg-config, gdb), Go
  1.27.2, Rust 1.99.1 (rustup 1.29.1), Temurin JDK 21.0.12.1+1, Gradle 9.8.1,
  Maven 3.10.0, each proven by a build-and-test smoke. Compressed sizes
  (linux/amd64, CI-measured): slim ≈ 464 MB, polyglot ≈ 1.2 GB (uncompressed 1.3 GB → 3.0 GB). The slim
  tags keep their contents (asserted toolchain-free by the smoke); agent CLIs
  re-snapshotted as of the build date. No fleet rolled.
- **0.2.3** — re-snapshot cut for the alissa CLI: picks up the paste lead-in
  (ali-fhr/studio.alissa.app#1590) so managed Claude Code sessions no longer
  refuse a paste-sized dispatch as "only pasted text" (Claude Code ≥ 2.1.283
  wraps one input chunk > 800 chars in `<pasted_content>`). Agent CLIs as of
  the build date. Image-input change: the `SNAPSHOT_STAMP` build arg so the
  unpinned install layers are never served from cache (found on this very
  release: the trial build shipped the 0.2.2 bundle as CACHED).
- **0.2.2** — re-snapshot: claude-code 2.1.283 (Opus 5.5 aware — ≥ 2.1.280
  knows `claude-opus-5-5` as the default Opus), codex 0.157.1, pi 0.73.1, as
  of the build date (2026-09-27). No image-input changes.
- **0.2.1** — re-snapshot: claude-code 2.1.263 (≥ 2.1.251, required by
  `claude-fable-5-1`). No image-input changes.
- **0.2.0** — agent CLIs codex and pi added alongside claude-code; CI version
  guard.
- **0.1.0** — first release of the base image.

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
