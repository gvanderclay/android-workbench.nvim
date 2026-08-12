# Release evidence

This ledger records reproducible release checks. Annotated tag `v0.1.0` resolves
to exact verified commit `0caff50af8db68c8a8fbc4bf86a06a3f18f5582f`.

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
