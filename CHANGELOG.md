# Changelog

Android Workbench is still unreleased. This file records user-visible changes
while the first pre-1.0 release gates remain open.

## Unreleased

### Added

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
