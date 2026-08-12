# Changelog

Android Workbench is still unreleased. This file records user-visible changes
while the first pre-1.0 release gates remain open.

## Unreleased

### Added

- A documented pre-1.0 Lua facade covering contexts, callbacks, handles,
  action results, structured errors, ownership, and shutdown.
- An explicit list of intentional constructor modules and private runtime
  modules.

### Changed

- `setup()` now returns no private effective-configuration snapshot.
- Operational failures now cross the facade as owned tables containing only
  `code`, `message`, optional `root`, and optional `details`.
- Failed async callbacks now return `(error, nil)` consistently.

### Removed

- The internal `_notify` helper from the public facade.
