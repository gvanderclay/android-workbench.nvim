# Android Workbench roadmap

## Current state

Android Workbench is now a standalone, source-visible pre-release development
repository. The runtime layout, bundled Gradle provider, command entry, vimdoc,
focused contracts, clean package smoke, and initial CI definition have been
extracted without changing the module namespace, `:Android` grammar, or state
location.

This is not a released or licensed plugin. Repository visibility grants no
reuse license. The work below is ordered by user impact and correctness rather
than feature count.

## Extraction baseline

- [x] Place `lua/android_workbench/**`, the bundled Gradle init script,
  `plugin/android-workbench.lua`, vimdoc/tags, and focused tests in an ordinary
  Neovim runtime layout.
- [x] Add isolated `make test-contract` and `make test-package` lanes that do
  not load or install external consumer dependencies.
- [x] Add a clean package smoke for startup, `:Android`, setup/App laziness, no
  package mappings or eager optional providers, help, health, and the bundled
  Gradle asset.
- [x] Add an initial Neovim 0.12.4 Linux/macOS CI definition that runs the
  standalone checks and formatting verification.
- [x] Move durable architecture and design rationale into the package
  repository while leaving consumer mappings and provider composition outside.
- [x] Make an external consumer configuration use the exact repository package
  and pinned revision, retain only a small coexistence/configuration smoke
  there, and remove its duplicate in-tree runtime, tests, and vimdoc.
- [x] Confirm the first remote CI run succeeds from the public repository.

The extraction baseline establishes compartmentalized ownership. It does not
close the runtime or release gates below.

## R1 — Runtime containment and owned data

Complete these correctness changes before treating the standalone package as a
release candidate.

### R1.1 Irreversible shutdown

- [x] Add a private shutdown-only abandon transition spanning `App` and
  execution orchestration.
- [x] If a child refuses cancellation or cannot be cancelled, allow it to
  finish privately while suppressing late ADB, Logcat, problem, notification,
  public-callback, and replacement-App side effects.
- [x] Cover delayed cancellation refusal, a late successful Run terminal, and a
  fresh replacement App in one focused regression matrix.

Ordinary user cancellation may remain active when a child refuses to stop;
shutdown is the stronger irreversible boundary.

### R1.2 Public result ownership

- [x] Return owned target, device, status, and error DTO members from facade
  workflows rather than Session-retained tables.
- [x] Preserve intentionally identity-bearing handles without blindly deep
  copying lifecycle objects.
- [x] Prove mutating any earlier public result cannot change later target
  resolution, Gradle argv, state, or device identity.

### R1.3 Complete discovery normalization

- [x] Extract one provider-neutral closed snapshot normalizer and owned copy.
- [x] Apply it to bundled and custom discovery before Session caching.
- [x] Validate bounds, arrays, build/target/task identities, derived task names,
  uniqueness, exact root, and cross-collection consistency.
- [x] Prove malformed, partial, or mutating custom snapshots cannot reach a
  runner, ADB service, state adapter, or current snapshot.

This closes an adapter containment problem. It is not a shell-injection claim;
Workbench already executes direct argv.

### R1.4 Logcat byte bounds

- [x] Bound native Logcat logical-line and retained-record bytes in addition to
  record count.
- [x] Discard through the next newline after an oversized record and
  resynchronize without manufacturing a partial record.
- [x] Cover oversized single chunks, split chunks, recovery, teardown, and
  bounded retained state.

## R2 — Effective native defaults and public boundary

### R2.0 Discoverable native Logcat controls

- [x] Keep application/device identity, stream state, and common controls
  visible in a window-local bar while records follow the tail.
- [x] Add buffer-local shortcut help that closes with the stream and exposes
  every native Logcat action without a global mapping or dependency.
- [x] Keep the scrolling buffer record-only while preserving user `FileType`
  overrides for native buffer mappings.

### R2.1 Inspectable native task output

- [ ] Add a bounded visible and reopenable owner for native runner output.
- [ ] Keep recognized source problems in the configured problem sink while
  leaving complete locationless/unrecognized failure output inspectable.
- [ ] Do not make Overseer required and do not add automatic provider detection.
- [ ] Prove command users can reopen the latest root/task output after terminal
  success or failure without taking over unrelated buffers or windows.

### R2.2 Deliberate pre-1.0 API

- [ ] Define the supported facade, module, context, callback, handle, result,
  and structured-error surface.
- [ ] Remove, privatize, or explicitly support `_notify` and the current
  `setup()` return instead of exposing them accidentally.
- [ ] Return owned DTOs, state callback timing and exactly-once rules, and
  document shutdown semantics.
- [ ] Treat internal lifecycle/model modules as private even though Lua can
  require them.
- [ ] Create an `Unreleased` changelog once the public surface is selected.

### R2.3 Port maturity

- [ ] Fully document picker, runner, and problem-sink DTOs and conformance first;
  they are the demonstrated external composition seams.
- [ ] Classify remaining semantic ports as supported or experimental during
  `0.x` instead of implying equal stability.
- [ ] Document the five-method public ADB service and the native emulator's
  conditional private ADB capabilities. Do not widen the general ADB port just
  to expose native implementation details.
- [ ] Add contract fixtures for each port promoted to supported status.

### R2.4 Consumer-safe context query

- [ ] Add a narrow, side-effect-free facade query for whether a path/buffer is
  under a Workbench Gradle root.
- [ ] Move consumer mapping installation off direct
  `require('android_workbench.root')` access.
- [ ] Keep the resolver implementation and its filesystem seams private.

### R2.5 Bounded package patches

- [ ] Register `:Android` without silently overwriting an existing command.
- [ ] Make health reject a non-file or non-executable Gradle wrapper using the
  same prerequisite rule as discovery.
- [ ] Add direct Telescope adapter tests for selection, cancellation, picker
  wipeout, and exactly-once completion.
- [ ] Keep the optional Overseer adapter's overrideable output/disposal behavior;
  choosing that adapter is consumer policy, not core leakage.

## R3 — Release evidence

These gates are required for a licensed `v0.1.0`, not for ordinary development
in the source-visible repository.

### R3.1 License and provenance

- [ ] Have the owner select a license and add the complete holder/year notice.
- [ ] Inventory the Lua source, tests, vimdoc, and bundled Gradle script for
  copied or adapted material and record any attribution obligations.
- [ ] Add `NOTICE` only if that inventory establishes a need.
- [ ] State the selected license in the README. Do not copy the incomplete
  license text from the former embedded configuration.

### R3.2 Reproducible package verification

- [ ] Record a successful remote CI run on every OS/Neovim version claimed by
  the first support statement.
- [ ] Keep fast package contracts isolated from user configuration, network
  installation, Android SDK state, and arbitrary projects.
- [ ] Add a reproducible real Gradle emitter-to-decoder fixture at the claimed
  endpoints, initially the recorded Gradle 7.3.3 and current endpoint.
- [ ] Cover composite identity, exact task execution, and a second
  configuration-cache run in that fixture.
- [ ] Run a minimal Android fixture at the exact Gradle 7.3.3/AGP 7.1.3 floor
  and one chosen current pair before advertising those pairs as supported.
- [ ] Load pinned/claimed Telescope and Overseer revisions in a small real
  adapter smoke; keep existing fakes for exhaustive lifecycle failures.

Do not adopt Gradle TestKit merely because it exists. A smaller replayable
wrapper fixture is acceptable if it evaluates the shipped provider and decoder
through the real execution path.

### R3.3 Outcome-based daily use

- [ ] Use the exact extracted package for routine Build, Run, application Stop,
  Logcat, emulator start/stop, and arbitrary Gradle tasks.
- [ ] Exercise recognized source failures and locationless failures through the
  final native/default output design.
- [ ] Exercise cancellation and retry, Neovim restart, package update, multiple
  roots, and worktree switching without state or operation leakage.
- [ ] Resolve every remaining blocker/high issue or record an explicit accepted
  limitation with user impact.

Completion is based on these outcomes, not an arbitrary number of days or a
feature-count comparison.

### R3.4 First pre-1.0 release

- [ ] Make the README support statement match verified OS, Neovim, Gradle, AGP,
  and optional-adapter evidence exactly.
- [ ] State Windows as not currently supported rather than promising an
  untested wrapper path.
- [ ] Document a simple `0.x` change policy and populate the changelog.
- [ ] Rerun standalone CI and the selected manual outcome checklist from the
  exact release commit.
- [ ] Tag `v0.1.0` only after licensing, provenance, runtime, API, verification,
  and daily-use gates are complete.

## Deferred until demonstrated demand

- Windows `gradlew.bat` support and broad historical Gradle/AGP matrices.
- APK browsing, standalone install/uninstall/clear-data commands, deep links,
  custom activities, launch arguments, richer run configurations, wireless
  pairing, screenshots, and SDK management.
- Reading Android Studio state, embedding the emulator, and AVD creation,
  deletion, wiping, cold boot, or snapshot management.
- Kotlin/Java LSP, formatting, DAP, test frameworks, KMP/iOS, autosave, and file
  watching.
- Provider registries, dependency-injection frameworks, automatic optional-
  plugin detection, a generic task framework, or file-size-driven module splits.
- LuaRocks publication, plugin-registry submission, release bots, a runtime
  version module, or a package schema without a selected release need.

New work enters the active roadmap only when a concrete workflow demonstrates
its value and ownership.
