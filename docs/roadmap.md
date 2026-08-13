# Android Workbench roadmap

## Current state

Android Workbench is an MIT-licensed Neovim plugin with three published
releases. It works without optional dependencies. Vimdoc defines its pre-1.0
Lua facade, and its compatibility claims are backed by real Gradle fixtures and
live Android checks.

| Release | Main change |
| --- | --- |
| [`v0.1.0`](https://github.com/gvanderclay/android-workbench.nvim/releases/tag/v0.1.0) | Standalone package, public facade, native task output, Logcat controls, and release verification |
| [`v0.2.0`](https://github.com/gvanderclay/android-workbench.nvim/releases/tag/v0.2.0) | Independent app/device Logcat sessions with bounded hidden history |
| [`v0.3.0`](https://github.com/gvanderclay/android-workbench.nvim/releases/tag/v0.3.0) | Project-local emulator manager, Cold Boot, and shutdown fixes |

The [changelog](../CHANGELOG.md) lists user-visible changes. The
[release evidence](release-evidence.md) records the checks behind each release.

## Direction before 1.0

The plugin remains in `0.x`. The facade and replacement ports documented in
vimdoc are the intended public surface, but a minor `0.x` release may still
contain breaking changes. Compatibility changes must be stated in the
changelog and release notes.

Work should continue to favor complete Android workflows over a broad IDE
feature list. A new feature belongs here only after a concrete workflow shows
why the existing commands or extension points are insufficient.

No feature milestone is currently selected. Maintenance work can proceed when
it preserves the documented boundary and has a focused regression or
verification case.

## Release requirements

Before a tag is published:

- The standalone contract, package, formatting, help, and diff checks must pass
  from the release commit on every claimed CI platform.
- Changes to Gradle discovery, its protocol, or compatibility claims require
  the real Gradle and Android Gradle Plugin fixture.
- Changes to optional integrations require the pinned Telescope and Overseer
  checks.
- Changes to device, emulator, or Logcat lifecycle behavior require the
  relevant live Android workflow when isolated tests cannot establish the
  result.
- Vimdoc, the changelog, release notes, and release evidence must agree with the
  shipped behavior.
- Publishing a tag or GitHub release requires explicit maintainer approval.

## Deferred until demonstrated demand

- Windows `gradlew.bat` support and broad historical Gradle/AGP matrices.
- APK browsing, standalone install/uninstall/clear-data commands, deep links,
  custom activities, launch arguments, richer run configurations, wireless
  pairing, screenshots, and SDK management.
- Reading Android Studio state, embedding the emulator, and AVD creation,
  deletion, wiping, or snapshot management.
- Kotlin/Java LSP, formatting, DAP, test frameworks, KMP/iOS, autosave, and file
  watching.
- Provider registries, dependency-injection frameworks, automatic optional
  plugin detection, a generic task framework, or file-size-driven module
  splits.
- LuaRocks publication, plugin-registry submission, release bots, a runtime
  version module, or a package schema without a selected release need.

Deferred items are not a promised backlog. They are boundaries that may be
revisited when a real workflow justifies the added ownership and lifecycle
cost.
