# Release evidence

This ledger records reproducible release checks. Annotated tag `v0.1.0` resolves
to exact verified commit `0caff50af8db68c8a8fbc4bf86a06a3f18f5582f`;
annotated tag `v0.2.0` resolves to exact verified commit
`12723a34bdc23c1cf949f8f6188ecedb65e8a792`; annotated tag `v0.3.0`
resolves to exact verified commit
`20160884e91bc40b338725e0b651de208a305212`.

## Standalone CI

Release commit `0caff50af8db68c8a8fbc4bf86a06a3f18f5582f` passed
[CI run 31614010533](https://github.com/gvanderclay/android-workbench.nvim/actions/runs/31614010533)
on 2026-08-12 in both claimed jobs:

- Neovim 0.12.4 on `ubuntu-latest`
- Neovim 0.12.4 on `macos-latest`

Both jobs ran `make test`; the Linux job also ran the pinned StyLua 2.5.2
format check. The workflow and actions are SHA-pinned.

## Isolated package checks

`make test` passed on the exact release commit on 2026-08-12 with Neovim 0.12.4.
Its 14 contract suites and two package smokes use a clean init, isolated XDG
directories, no user configuration, no network installation, no Android SDK
state, and only disposable project roots. `make test-format`, help-tag
generation, `git diff --check`, and ShellCheck for both integration scripts also
passed.

## Real Gradle and Android endpoints

`make test-integration-gradle` passed on the exact release commit on 2026-08-12
on macOS 26.5.2 arm64, Neovim 0.12.4, and Java 17.0.9. The tracked disposable
fixture verified both:

- Gradle 7.3.3 with AGP 7.1.3 and Android platform 30
- Gradle 9.1.0 with AGP 9.0.1 and Android platform 36

At each endpoint the public facade decoded two real Android targets on two
successive configuration-cache discovery runs, offered the included-build task
as `:included:includedProbe`, executed that exact ID, and assembled the debug
APK. The harness deletes all project state and build output when it exits.
Missing Gradle distributions are fetched from the official distribution
service and checked against their published SHA-256 digests.

## Optional adapters

`make test-integration-adapters` passed on the exact release commit on
2026-08-12 with the exact Telescope, Plenary, and Overseer revisions recorded in
[`tests/integration/adapters/README.md`](../tests/integration/adapters/README.md).
The real Telescope picker returned its current item, and the real Overseer task
streamed and completed a direct `nvim --version` invocation. Exhaustive
lifecycle failures remain in the isolated fake-based contracts.

## Outcome-based daily use

Commit `cea05c401ea7273f22ff000ecd2c9e75aba02cf6` passed the R3.3
outcome checklist on 2026-08-12 with Neovim 0.12.4 on macOS 26.5.2 arm64. The
sibling consumer lock and managed checkout resolved that exact package commit;
its isolated consumer smoke, startup, and Stow simulation passed before the
lock update was committed.

The ignored local Android fixture uses Gradle 9.1.0, AGP 9.0.1, and Android
platform 36. It provided these live outcomes:

- Two real Builds succeeded, and a registered arbitrary Gradle task completed.
- Run, application Stop, process restart, and app-scoped Logcat passed on a
  physical Android 15/API 35 phone. Logcat retained the fixture launch marker,
  and final teardown left no app or phone-targeted Logcat process.
- Workbench started one stopped API 36.1 AVD while another AVD was online, ran
  and restarted the fixture application, retained app-scoped Logcat records,
  then stopped only the AVD it started. The pre-existing AVD remained online,
  and no started-AVD or Logcat process survived.
- A real Java missing-type failure returned one exact source location to the
  default Android-owned quickfix list without opening that window. The complete
  compiler text remained available in native task output. Removing the error
  restored successful Builds.
- A locationless debug-signing mismatch returned no source problems and kept
  the complete Gradle failure in native task output.
- Cancelling a deliberately slow real Gradle task completed once as cancelled,
  cleared only its root operation, and allowed an immediate successful retry.
- Exiting Neovim with Logcat active left the application running by design but
  no Logcat reader or Neovim process. A fresh process loaded only the saved
  app, variant, and device selection and started a new independent workflow.
- Separate main and linked Git worktrees retained different variant selections.
  A task in one root remained active while the other root built successfully;
  cancelling the first did not affect the second. A fresh Neovim process loaded
  both selections and refreshed both roots concurrently without crossing
  results or operations.

No remaining Android Workbench blocker or high-severity issue reproduced during
the checklist. Two local harness faults were corrected before accepting their
evidence: reused state could override a requested AVD, and separate isolated
configs generated incompatible debug certificates. Neither required a runtime
change. Generated projects, worktrees, build output, and owned processes were
removed after their checks.

## Post-release multi-session Logcat

Commit `fc2d53386b8c392180f887af1f20a17d15b902ad` passed the R4.6
same-device/different-app gate on 2026-08-12 with Neovim 0.12.4, ADB 37.0.0,
and an Android 16/API 36 `sdk_gphone64_arm64` emulator.

Two application sessions retained separate launch markers through five picker
switches in one unchanged three-window layout. Their device-wide readers kept
the same PIDs through an application process restart and a reinstall that
changed the selected package UID from 10228 to 10230. The hidden session kept
26 records and 3,424 raw bytes in one unlinked private spool descriptor. One
exact-session stop left its sibling reader live; stop-all then stopped the
remaining reader with no refusal.

Before normal editor exit, two new readers measured 0.0% CPU and 8,112 and
8,064 KiB RSS after five seconds. `:qa!` closed both readers, their UID refresh
queries, the smoke Neovim process, and the hidden spool owner. The fixture apps
were then force-stopped, and Gradle `clean` removed generated build output. The
full argv, PIDs, UIDs, marker counts, storage counters, and cleanup checks are
also recorded in the owning
[`docs/logcat-sessions.md`](logcat-sessions.md) checkpoint.

## Exact release checklist

Release commit `0caff50af8db68c8a8fbc4bf86a06a3f18f5582f` passed the selected
R3.4 outcome checklist on 2026-08-12:

- Two real Builds passed. A deliberately slow registered task accepted
  cancellation, completed once as cancelled, cleared its root operation, and
  succeeded on immediate retry.
- An intentional Java missing-type failure produced the exact source location
  in the Android-owned quickfix list without opening it. Native task output kept
  the full compiler line, and two Builds passed after the source was restored.
- With one AVD already online, Workbench started a second stopped AVD, ran and
  restarted the fixture application, retained app-scoped Logcat records, and
  stopped only the second AVD.
- Exiting Neovim with Logcat active left no reader or Neovim process. A fresh
  process loaded only saved selection state and completed a new independent
  Run, Logcat, and Stop workflow.
- Separate main and linked Git worktrees retained independent selections and
  operations during concurrent refresh, Build, task cancellation, and restart.
- A disposable sibling-consumer worktree advanced only the Android Workbench
  lock to the exact release commit. Pack-ui background checking was disabled in
  that disposable config so unrelated revisions could not drift. The consumer
  smoke and full isolated headless startup passed, and the installed package
  checkout matched the release commit.

The test-owned AVD, processes, build output, linked worktree, consumer worktree,
and isolated consumer data were removed. The pre-existing AVD remained online,
and the real consumer checkout was not changed. The annotated `v0.1.0` tag was
created and pushed only after these checks passed; its remote peeled tag resolves
to the exact release commit above.

## `v0.2.0` release

Release candidate `12723a34bdc23c1cf949f8f6188ecedb65e8a792` passed R5
verification on 2026-08-12. Its `lua/` and `plugin/` runtime is byte-identical
to device-tested commit `fc2d53386b8c392180f887af1f20a17d15b902ad`, so the
R4.6 two-application Android 16 evidence above applies without another device
run.

A disposable clean worktree at the exact candidate passed help-tag generation
without a diff, all 15 contract suites, both package smokes, StyLua 2.5.2,
ShellCheck 0.11.0, and `git diff --check`. The real integration gate again
passed Gradle 7.3.3 with AGP 7.1.3, Gradle 9.1.0 with AGP 9.0.1, and the pinned
Telescope, Plenary, and Overseer revisions. The fixtures removed their project
state and build output, and the disposable worktree was deleted.

The exact candidate passed
[CI run 31654448695](https://github.com/gvanderclay/android-workbench.nvim/actions/runs/31654448695)
with Neovim 0.12.4 on `ubuntu-latest` and `macos-latest`. Both jobs ran the
standalone checks; Linux also ran the pinned StyLua format check.

Sibling-consumer commit `c4982ced1cf830f9470cb0fa5cfc81a93affd91a`
pins the candidate and asserts the public Logcat session-selection and stop-all
methods. A disposable worktree from that exact consumer commit passed its
Android Workbench smoke and full headless startup with isolated Neovim data;
only pack-ui background checking was disabled to prevent unrelated lock drift.
The installed package checkout was clean at the exact release candidate. Stow
simulation and diff checks passed, all disposable data was removed, and the
consumer commit was pushed separately.

Remote annotated tag object `dad6ef1bc294bc13a4fed1ab17cfd0b904c73054`
peels to the candidate above. A public, non-draft GitHub prerelease named
`Android Workbench v0.2.0` was published on 2026-08-13 UTC at
[`v0.2.0`](https://github.com/gvanderclay/android-workbench.nvim/releases/tag/v0.2.0).
Its published body matches the curated release notes derived from the `0.2.0`
changelog section.

## `v0.3.0` release

Release candidate `20160884e91bc40b338725e0b651de208a305212` passed R7
verification on 2026-08-12. Its `lua/` and `plugin/` runtime is byte-identical
to reviewed emulator-manager candidate
`fb5f2837e8138c0a5b7045c1e571e75e645ce6e8`, whose state-aware Start, Stop,
and Cold Boot actions passed the recorded live local-AVD checks.

A disposable clean worktree at the exact release candidate passed help-tag
generation without a diff, all 15 contract suites, both package smokes, StyLua
2.5.2, ShellCheck 0.11.0, and `git diff --check`. The real integration gate
passed Gradle 7.3.3 with AGP 7.1.3, Gradle 9.1.0 with AGP 9.0.1, and the pinned
Telescope, Plenary, and Overseer revisions. The fixtures removed their project
state and build output, and the disposable worktree was removed.

The exact candidate passed
[CI run 31660894527](https://github.com/gvanderclay/android-workbench.nvim/actions/runs/31660894527)
with Neovim 0.12.4 on `ubuntu-latest` and `macos-latest`. Both jobs ran the
standalone checks; Linux also ran the pinned StyLua format check.

Sibling-consumer commit `043076924233c4bf7f2006890885ec6bad08d848`
pins the exact candidate. A disposable worktree from that consumer commit
installed a clean package checkout at the candidate and passed its Android
Workbench smoke, full headless startup, isolated Stow simulation, and diff
check. The live installed package checkout and unrelated Zen edit were not
changed. The consumer commit was pushed separately.

Remote annotated tag object `a3993026e75424ac4489f5ee6a0107e825d4d9d4`
peels to the candidate above. A public, non-draft, non-prerelease GitHub release
named `Android Workbench v0.3.0` was published on 2026-08-13 UTC at
[`v0.3.0`](https://github.com/gvanderclay/android-workbench.nvim/releases/tag/v0.3.0).
It is the repository's latest release, and its published body matches the
curated `v0.3.0` release notes.
