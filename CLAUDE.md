# alissa-loopwork — session ground rules

This repo ships the **loopwork base image** (`ghcr.io/ali-fhr/alissa-loopwork-base`),
the shared substrate under the loopwork daemon images. `README.md` is the canonical
doc (why the base exists, what's in it vs the leaves, the leaf contract, releasing) —
read it first. This file adds only what a working session needs beyond it.

## The contract you must not break casually

The daemon repos (`alissa-github-develop-daemon`, `alissa-github-review-daemon`,
under fahera-mx) build leaf Dockerfiles `FROM` this image and depend on the **leaf
contract** in README.md: the entrypoint hook path (`/usr/local/bin/entrypoint.sh`),
the `alissa` user (uid 1000), `/workspace`, the ENV skeleton, the git rewrites, and
the pre-seeded claude first-run files. Changing any of those is a **breaking change**:
check both consumers' `docker/claude/` first, and version accordingly.

Semver intent: **patch** = re-snapshot of the unpinned CLIs / non-contract fixes;
**minor** = additive (new tool, new agent CLI); **major** = leaf-contract break.

## Releasing & CI mechanics (the non-obvious parts)

- Releases are **VERSION-file driven**: bump `VERSION` in the PR; on merge,
  `release.yml` creates the `vX.Y.Z` tag and **calls** `publish.yml`. The call is
  load-bearing — tags created with `GITHUB_TOKEN` do NOT trigger other workflows
  (GitHub's recursion guard). Don't "simplify" release.yml to rely on its tag push.
- `publish.yml` computes image tags from the version in **bash**, not
  metadata-action — on the workflow_call path the git ref is a branch, so
  ref-derived tags would be wrong.
- CI's `version-guard` job fails a PR that touches an **image input** without
  bumping VERSION, or sets VERSION to an already-tagged value. The image-input
  regex lives in `ci.yml` — extend it when you add files that get built or COPYed
  into the image.
- Verify locally with `tests/run.sh` (build + offline smoke). Keep `tests/smoke.sh`
  runnable with **no network and no tokens** — it runs identically in CI and gates
  every publish.

## Traps already hit once

- **pi's npm package is `@mariozechner/pi-coding-agent`** (bin `pi`).
  `@mariozechner/pi` is a different tool (`pi-pods`). Verify bins against the npm
  registry before adding/renaming agent packages.
- The base image is **public on GHCR by requirement**: Railway can't pull private
  base images at build time. Never add anything secret-shaped to this image or its
  build args (`docker history` leaks ARGs). Package visibility is already set;
  it does not need re-flipping per release.
- `gh pr edit` fails in this repo (GraphQL projectCards deprecation). Use
  `gh api -X PATCH repos/ali-fhr/alissa-loopwork/pulls/<n> -f body=…`, and request
  reviewers with JSON via `--input -` (the `-f 'reviewers[]=…'` form 422s).

## Ways of work

This is an **ali-fhr** repo not yet wired to the autonomous loopwork pipeline
(no autodev BOW, no daemon allowlist entry) — work here is done **locally** in an
Alissa workspace session: Alissa task first, `TASK-<id>-DESC` worktree branch,
draft PR → ready-for-review flip, PR URL as task evidence, alissa-app co-author
trailer (the `alissa-code-git` / `alissa-code-workspace` skills). If the repo gets
loop-wired later, prefer feeding tasks instead.

## Roadmap anchors (see README for detail)

Planned next: shared entrypoint lib shipped by this image (`/usr/local/lib/loopwork/`)
extracted from the daemons' divergent entrypoints; headless first-run seeding for
codex/pi when a leaf wires them into worker profiles.
