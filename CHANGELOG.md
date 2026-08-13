# Changelog

This file records user-visible Android Workbench changes.

## Unreleased

### Added

- A project-local emulator manager that lists every installed AVD with its
  running state and offers Start or Stop without changing target selection.
- Native Cold Boot for stopped AVDs, using the existing bounded readiness and
  cancellation lifecycle without wiping user data.

### Fixed

- Native Logcat shutdown now irreversibly closes its view, timers, pickers, and
  private history even when the underlying reader refuses cancellation.

## 0.2.0 - 2026-08-12

### Added

- Private bounded temporary storage for hidden native Logcat history, with
  ordered restoration while capture remains active.
- Independent root-local Logcat sessions keyed by application ID and device
  serial, including exact reuse and sibling-safe lifecycle handling.
- Root-local Logcat session selection and best-effort stop-all commands, facade
  methods, and contextual actions with bounded refusal reporting.
- A visible native Logcat session switcher with buffer-local `S` and shortcut
  help, backed by the existing root-local picker.

### Changed

- Native Logcat handles created by one presenter now switch independent session
  buffers through its owned bottom split without replacing unrelated windows.
- Native Logcat now reads device-wide output and applies a refreshed package
  filter inside Workbench, preserving a session across package reinstalls and
  reading the device's full bounded history by default.

### Fixed

- Normal Neovim exit now shuts down an already-loaded Workbench instance, so
  owned Logcat readers cannot survive `:qa!` while an unused package remains
  unloaded.

## 0.1.0 - 2026-08-12

### Added

- MIT licensing and a recorded source-provenance inventory.
- Reproducible real Gradle/AGP and pinned optional-adapter integration gates.
- A documented pre-1.0 Lua facade covering contexts, callbacks, handles,
  action results, structured errors, ownership, and shutdown.
- An explicit list of intentional constructor modules and private runtime
  modules.
- A side-effect-free `is_project()` facade query for contextual consumer
  policy without private root-resolver access.
- Supported `0.x` picker, runner, and problem-sink DTO contracts.
- A supported five-method `0.x` ADB service contract, including its conditional
  native emulator and Logcat composition limits.
- Explicit `0.x` maturity labels for every replacement port.

### Changed

- `setup()` now returns no private effective-configuration snapshot.
- Operational failures now cross the facade as owned tables containing only
  `code`, `message`, optional `root`, and optional `details`.
- Failed async callbacks now return `(error, nil)` consistently.
- Runner request mutation can no longer alter canonical task identity, and
  unknown or wrongly typed runner result fields no longer cross the facade.
- Run and Stop now revalidate custom ADB result identity and no longer expose
  undocumented adapter payloads.
- Plugin startup now preserves an existing global `:Android` command and emits
  one warning instead of replacing it.
- Health now applies discovery's regular-file and executable checks to the
  current project's Gradle wrapper.
- Telescope selection now shares the adapter's terminal guard, preventing a
  duplicate or late selection callback after completion or picker wipeout.

### Removed

- The internal `_notify` helper from the public facade.
