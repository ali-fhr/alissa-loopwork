# Polyglot smoke samples

Tiny sample projects, one per language, that `smoke.sh` here compiles and
tests **as the unprivileged `alissa` user in a login shell** inside the
`polyglot` image variant (the PATH a tmux-spawned worker session gets). Each
has exactly one passing test; any build or test failure fails the smoke, and
the smoke gates both CI and publishing.

| dir | language | build + test |
|---|---|---|
| `c/` | C | `make test` |
| `cpp/` | C++ | `cmake -S . -B build && cmake --build build && ctest --test-dir build` |
| `go/` | Go | `go vet ./... && go test ./...` |
| `rust/` | Rust | `cargo test && cargo clippy -- -D warnings && cargo fmt --check` |
| `kotlin/` | Kotlin + Java | `gradle test` (Kotlin calls a Java class; JUnit 5 via kotlin-test) |

Plus `mvn --version` for Maven.

Network: only the Gradle sample needs it (the Kotlin Gradle plugin and
kotlin-test/JUnit come from the Gradle Plugin Portal and Maven Central). The
others have no third-party dependencies. `tests/smoke.sh` — the offline image
contract smoke — stays network-free.

Run locally (Docker required):

```sh
tests/run.sh polyglot     # build --target polyglot, contract smoke, then this smoke
tests/run.sh all          # slim + polyglot
```

When bumping the Kotlin Gradle plugin in `kotlin/build.gradle.kts`, check it
supports the image's Gradle version (Dockerfile `GRADLE_VERSION`).
