# Repository guide

## Purpose and status

This repository contains Android Workbench, a focused Neovim plugin for Android
and Gradle orchestration. It is an MIT-licensed plugin with an initial
`v0.1.0` tag and no plugin-registry publication. Do not create or change a tag,
publish a GitHub release, submit to a plugin registry, or change the MIT license
without explicit owner approval and completion of the applicable release gates
in `docs/roadmap.md`.

## Session continuity

At the start of a new Claude or Codex session, read the local
`.claude/context/session-handoff.md` when it exists before choosing work. It
records the latest checkout-specific handoff, user preferences, and recommended
next checkpoint. Verify its commit and status claims against Git before acting;
the tracked vimdoc, architecture, decisions, tests, and roadmap remain the
authoritative sources.

Update the handoff at the end of a meaningful development session when the
current state, accepted direction, manual evidence, or next recommended task
changes. Keep it concise and local-only; do not copy transcripts or temporary
review artifacts into it.

The plugin owns Android project discovery, target and device state, AVD
lifecycle, exact Gradle execution, Android application actions, build problems,
and app-scoped Logcat. Kotlin/Java LSP, formatting, test frameworks, DAP,
autosave, file watching, KMP/iOS, SDK installation, and personal editor policy
are outside this repository.

## Before changing files

- Inspect `git status` and preserve unrelated or concurrent work.
- Do not stage, commit, push, publish, or change repository settings without
  explicit approval.
- Read the relevant implementation, focused tests, vimdoc, and owning design
  document before editing behavior.
- For structural or contract work, read
  `docs/architecture/android-workbench.md`, `docs/decisions.md`, and
  `docs/roadmap.md` first. Also read the local
  `.claude/rules/android-workbench.md` when it exists.
- Keep changes focused. Do not combine runtime fixes, refactors, features,
  compatibility work, and release scaffolding unless the task explicitly owns
  each part.
- Do not install dependencies or modify a consumer's Neovim configuration as a
  side effect of plugin work.
- Never commit secrets, local Android SDK state, project trust decisions,
  emulator state, generated Gradle output, or private machine paths.

## Repository layout

- `lua/android_workbench/`: plugin implementation. `app.lua` is the composition
  root; `init.lua` is the public Lua facade.
- `lua/android_workbench/gradle/android_workbench.init.gradle`: bundled runtime
  discovery provider. It must remain adjacent to `gradle/discovery.lua` unless
  the source-relative lookup changes deliberately.
- `plugin/android-workbench.lua`: thin, lazy `:Android` command registration.
- `doc/android-workbench.txt`: public user-visible behavior and API reference.
- `tests/`: isolated behavioral and package contracts.
- `docs/architecture/android-workbench.md`: durable internal ownership,
  dependency direction, and lifecycle invariants.
- `docs/decisions.md`: accepted design decisions and revisit triggers.
- `docs/roadmap.md`: pre-release hardening and release gates.
- `.claude/rules/android-workbench.md`: optional local implementation guidance;
  tracked architecture, decisions, and tests remain authoritative without it.

The owner's Telescope/Overseer selection, diagnostic presentation, keymaps,
WhichKey labels, and Kotlin setup live in the separate dotfiles repository.
They are a consumer of this package, not a second source of plugin behavior.

## Sources of truth

Use each document for one kind of truth:

1. `doc/android-workbench.txt` — public setup, commands, adapter contracts, and
   visible behavior.
2. `docs/architecture/android-workbench.md` — internal ownership and required
   lifecycle, trust, and data invariants.
3. `docs/decisions.md` — accepted rationale and explicit non-goals.
4. Focused tests — executable behavior and regression contracts.
5. `docs/roadmap.md` — sequencing and unresolved pre-release gates.
6. `lua/android_workbench/` — current implementation.

Implementation and documentation must agree. A behavior or API change updates
vimdoc and tests in the same change. An ownership or dependency change updates
the architecture document. A durable tradeoff updates the decision record. Do
not mark a roadmap gate complete until its verification passes and the task
actually includes that milestone bookkeeping.

## Change discipline

- Preserve the configuration-only, lazy `setup()` boundary.
- Preserve characterized and documented behavior unless the task explicitly
  changes it; focused regression tests are contracts, not incidental examples.
- Keep `App` as the composition root. Refactor by responsibility and lifecycle,
  not by file length.
- Keep core requests and results presentation-neutral. Optional integrations
  may implement one explicit port; they must not become hidden dependencies.
- Do not add global or personal mappings, WhichKey entries, global picker
  overrides, automatic plugin detection, or automatic Trouble behavior.
- Do not add a dependency-injection container, provider registry, generic task
  framework, or compatibility abstraction without a demonstrated consumer.
- Treat Gradle discovery and execution as project-code execution. Preserve
  trust immediately before each process, canonical roots, verified direct argv,
  bounded protocol data, cancellation, and root isolation.
- Treat custom adapters and picker results as untrusted data. Validate identity,
  shape, ownership, and bounds at the receiving boundary.
- Install operation identity and terminal guards before invoking an async port;
  adapters may call back synchronously.
- Keep every operation terminal exactly once. Late or stale callbacks must not
  mutate a newer generation or survive shutdown into user-visible side effects.
- Keep mutable state isolated by canonical checkout/worktree root. Included
  builds retain build-path identity inside that root.
- Preserve direct argv execution. Never compose a project command through a
  shell.
- Keep retained output, protocol records, waits, and Logcat history bounded.
- Do not widen scope to Windows wrappers, broad compatibility matrices, SDK
  management, AVD creation/deletion/wiping, screenshots, deep links, tests,
  DAP, or other Android IDE features without a separately accepted task.

The complete constraints and port calling conventions are in the scoped rule
and architecture guide; do not duplicate their details in ad hoc comments.

## Public and private boundaries

The intended pre-1.0 supported surface is the `:Android` command,
`require('android_workbench')`, `android_workbench.health`, and adapter
constructors explicitly documented in vimdoc. Internal lifecycle and model
modules are not public merely because Lua can require them.

The exact facade, result ownership, error envelope, and port stability levels
are still pre-release decisions in `docs/roadmap.md`. Do not imply stability in
new docs or examples before those gates close. In particular, avoid teaching
consumers to depend directly on `app`, `session`, `root`, `device`,
`execution`, `task_operation`, or Gradle model helpers.

## Minimal verification

Run relevant checks from the repository root and report anything skipped:

- All edits: `git diff --check`.
- All plugin changes: `make test`.
- Focused isolated contracts: `make test-contract`.
- Runtime layout, startup, help, health, and bundled asset:
  `make test-package`.
- Lua and runtime formatting: `make test-format`.
- Vimdoc changes: regenerate tags with
  `nvim --clean --headless '+helptags doc' '+qa'`, then rerun
  `make test-package`.
- Formatting changes: use the repository's existing formatter configuration;
  do not rewrite unrelated files.

Tests must not load the owner's dotfiles, install optional plugins, contact a
device/emulator, or evaluate an arbitrary real project unless the test is an
explicit integration gate with an isolated fixture. Keep real Gradle/AGP and
optional-provider checks separate from fast hermetic contracts.

Material changes to the bundled Gradle provider, wire protocol, decoder, or
compatibility claims must also consult the applicable real-Gradle gates in
`docs/roadmap.md`; run their fixture when available and report skipped evidence.
The sibling dotfiles consumer smoke is meaningful only after it pins the exact
package commit under review. Run it as a separate cutover gate when updating
that pin; do not treat a smoke against an older lock revision as evidence for
the current checkout or edit the consumer unless it is in scope.

## Release discipline

The repository uses the MIT License selected by the owner. Keep its holder/year
notice and `docs/provenance.md` accurate when adding material. Do not claim
public support from unit tests alone. A public tag requires the runtime,
default-output, API, licensing, clean-package/CI, real Gradle/AGP,
optional-adapter, and daily-use outcomes listed in `docs/roadmap.md`. No runtime
version module, package schema version, release bot, LuaRocks manifest, or
plugin-registry metadata is needed during pre-release development.
