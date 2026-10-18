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
| `ruby/` | Ruby | `bundle install --prefer-local && bundle exec rake test` (a gem-less lib, minitest via rake) |
| `php/` | PHP | `composer validate && composer install && vendor/bin/phpunit` (PSR-4 autoload, PHPUnit 13) |
| `dotnet/` | C# (.NET) | `dotnet test --project Adder.Tests/Adder.Tests.csproj` (a class library + an xunit.v3 test project on Microsoft.Testing.Platform) |

Plus `mvn --version` for Maven.

Network: the package-manager samples need it — Gradle (the Kotlin Gradle
plugin and kotlin-test/JUnit from the Gradle Plugin Portal and Maven Central),
Bundler (rubygems.org metadata; minitest and rake themselves are gems bundled
with the image's Ruby), Composer (PHPUnit from Packagist) and NuGet (xunit.v3
from nuget.org). C, C++, Go and Rust have no third-party dependencies.
`tests/smoke.sh` — the offline image contract smoke — stays network-free.

No lock files are committed: each run resolves the newest versions inside the
declared constraints, so a dependency release that breaks on the image's
toolchain shows up here first.

Run locally (Docker required):

```sh
tests/run.sh polyglot     # build --target polyglot, contract smoke, then this smoke
tests/run.sh all          # slim + polyglot
```

When bumping the Kotlin Gradle plugin in `kotlin/build.gradle.kts`, check it
supports the image's Gradle version (Dockerfile `GRADLE_VERSION`).
`dotnet/global.json` routes `dotnet test` through Microsoft.Testing.Platform
(required by xunit.v3's `mtp-v2` runner on the .NET 10 SDK) and accepts any
10.0.x SDK; moving the image to a new .NET LTS means bumping it and the
`TargetFramework` in `dotnet/Directory.Build.props`. PHPUnit 13 needs
PHP ≥ 8.4.1.
