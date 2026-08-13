# Release verification

This file records the checks used to support Android Workbench release claims.
The tag commits and CI runs are public; Android device checks are summarized
here because they are not suitable for hosted CI.

| Version | Tag commit | Publication |
| --- | --- | --- |
| `v0.1.0` | `0caff50af8db68c8a8fbc4bf86a06a3f18f5582f` | [GitHub prerelease](https://github.com/gvanderclay/android-workbench.nvim/releases/tag/v0.1.0) |
| `v0.2.0` | `12723a34bdc23c1cf949f8f6188ecedb65e8a792` | [GitHub prerelease](https://github.com/gvanderclay/android-workbench.nvim/releases/tag/v0.2.0) |
| `v0.3.0` | `20160884e91bc40b338725e0b651de208a305212` | [GitHub release](https://github.com/gvanderclay/android-workbench.nvim/releases/tag/v0.3.0) |

## Verification lanes

`make test` runs isolated contract suites and package smokes with a clean
Neovim configuration, disposable XDG directories, no network installation, no
Android SDK state, and no arbitrary Android project.

The separate integration command verifies the bundled discovery provider
against real Gradle and Android Gradle Plugin versions. It also loads pinned
Telescope, Plenary, and Overseer revisions. The fixture requirements and exact
adapter revisions are documented in
[`tests/integration/`](../tests/integration/).

Live Android checks cover workflows that hermetic tests cannot prove, such as
ADB process cleanup, application launches, emulator identity, and Logcat
behavior across package reinstalls.

## `v0.1.0`

The release commit passed
[CI run 31614010533](https://github.com/gvanderclay/android-workbench.nvim/actions/runs/31614010533)
on 2026-08-12 with Neovim 0.12.4 on both `ubuntu-latest` and `macos-latest`.
Both jobs ran the standalone checks; Linux also ran the pinned StyLua 2.5.2
format check. The workflow and actions were SHA-pinned.

Local release verification passed:

- 14 contract suites and both clean package smokes;
- StyLua, help-tag generation, `git diff --check`, and ShellCheck for the
  integration scripts;
- Gradle 7.3.3 with AGP 7.1.3 and Android platform 30;
- Gradle 9.1.0 with AGP 9.0.1 and Android platform 36; and
- the pinned Telescope, Plenary, and Overseer integration checks.

Both Gradle endpoints decoded two Android targets on successive
configuration-cache runs, retained included-build identity, executed
`:included:includedProbe`, and assembled the debug APK.

Live checks used Neovim 0.12.4 on macOS and the Gradle 9.1.0/AGP 9.0.1 Android
fixture. They covered:

- Build, Run, application Stop, process restart, and app-scoped Logcat on a
  physical Android 15 device;
- starting and stopping one API 36 AVD while another emulator remained online;
- recognized Java source failures in quickfix and locationless Gradle failures
  in native task output;
- cancellation of a slow Gradle task followed by an immediate successful
  retry;
- normal Neovim exit with Logcat active, followed by a clean new session; and
- independent selection and operation state across linked Git worktrees.

Each workflow ended without a Workbench-owned Logcat reader, test application
process, generated build directory, or disposable worktree left behind.

## `v0.2.0`

The release commit passed
[CI run 31654448695](https://github.com/gvanderclay/android-workbench.nvim/actions/runs/31654448695)
with Neovim 0.12.4 on `ubuntu-latest` and `macos-latest`. A clean checkout also
passed all 15 contract suites, both package smokes, StyLua 2.5.2, ShellCheck
0.11.0, help-tag generation, and `git diff --check`. The real Gradle and pinned
adapter checks passed again.

The released runtime matched the Android 16 live-tested runtime byte for byte.
That test kept two application sessions active on one emulator while switching
between them five times without replacing either reader or changing the window
layout. One application restarted and was reinstalled with a different UID;
its existing session continued to collect records.

A hidden session retained 26 records and 3,424 raw bytes in an unlinked private
spool file. Stopping one session left the other reader active. Stop-all removed
the remaining reader, and normal Neovim exit left no reader, package refresh,
Neovim process, or spool owner behind. More detail about the design and its
bounds is in the [multi-session Logcat record](logcat-sessions.md).

## `v0.3.0`

The release commit passed
[CI run 31660894527](https://github.com/gvanderclay/android-workbench.nvim/actions/runs/31660894527)
with Neovim 0.12.4 on `ubuntu-latest` and `macos-latest`. A clean checkout passed
all 15 contract suites, both package smokes, formatting, ShellCheck, help-tag
generation, `git diff --check`, the real Gradle matrix, and the pinned optional
adapter checks.

Live local-AVD testing verified that the project-local manager reported running
and stopped state correctly, offered only valid actions, started and stopped an
AVD without changing deployment selection, and Cold Booted a stopped AVD with
`-no-snapshot-load`. The AVD was returned to its original stopped state after
the check.

The annotated tag was published as the first ordinary GitHub release in the
project's `0.x` series. The pre-1.0 compatibility policy remains documented in
the README and release notes.
