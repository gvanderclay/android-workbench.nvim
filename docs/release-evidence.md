# Release evidence

This ledger records reproducible pre-release checks. A passing development
check does not replace the exact-release-commit rerun required by R3.4.

## Standalone CI

Commit `d636be4bb5e92853fa8c5cdebf7b9f3a64dcf59d` passed
[CI run 31560605058](https://github.com/gvanderclay/android-workbench.nvim/actions/runs/31560605058)
on 2026-08-11 in both claimed jobs:

- Neovim 0.12.4 on `ubuntu-latest`
- Neovim 0.12.4 on `macos-latest`

Both jobs ran `make test`; the Linux job also ran the pinned StyLua 2.5.2
format check. The workflow and actions are SHA-pinned.

## Isolated package checks

`make test` passed on 2026-08-11 with Neovim 0.12.4. Its 14 contract suites
and two package smokes use a clean init, isolated XDG directories, no user
configuration, no network installation, no Android SDK state, and only
disposable project roots. `make test-format`, help-tag generation, and
`git diff --check` also passed.

## Real Gradle and Android endpoints

`make test-integration-gradle` passed on 2026-08-11 on macOS 26.5.2 arm64,
Neovim 0.12.4, and Java 17.0.9. The tracked disposable fixture verified both:

- Gradle 7.3.3 with AGP 7.1.3 and Android platform 30
- Gradle 9.1.0 with AGP 9.0.1 and Android platform 36

At each endpoint the public facade decoded two real Android targets on two
successive configuration-cache discovery runs, offered the included-build task
as `:included:includedProbe`, executed that exact ID, and assembled the debug
APK. The harness deletes all project state and build output when it exits.
Missing Gradle distributions are fetched from the official distribution
service and checked against their published SHA-256 digests.

## Optional adapters

`make test-integration-adapters` passed on 2026-08-11 with the exact Telescope,
Plenary, and Overseer revisions recorded in
[`tests/integration/adapters/README.md`](../tests/integration/adapters/README.md).
The real Telescope picker returned its current item, and the real Overseer task
streamed and completed a direct `nvim --version` invocation. Exhaustive
lifecycle failures remain in the isolated fake-based contracts.
