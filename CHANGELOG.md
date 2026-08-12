# Changelog

Android Workbench is still unreleased. This file records user-visible changes
while the first pre-1.0 release gates remain open.

## Unreleased

### Added

- A documented pre-1.0 Lua facade covering contexts, callbacks, handles,
  action results, structured errors, ownership, and shutdown.
- An explicit list of intentional constructor modules and private runtime
  modules.
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

### Removed

- The internal `_notify` helper from the public facade.
