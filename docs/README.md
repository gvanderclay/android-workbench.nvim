# Documentation

Android Workbench keeps user instructions, API reference, design records, and
release evidence separate so each document has one job.

## Using Android Workbench

- The [README](../README.md) covers requirements, installation, first use, and
  common configuration.
- `:help android-workbench` is the full command, configuration, Lua API, adapter,
  and troubleshooting reference. Its source is
  [`doc/android-workbench.txt`](../doc/android-workbench.txt).
- The [changelog](../CHANGELOG.md) records user-visible changes by release.

## Contributing

- [CONTRIBUTING.md](../CONTRIBUTING.md) explains bug reports, minimal
  reproductions, project scope, and local verification.
- The [architecture guide](architecture/android-workbench.md) defines internal
  ownership, dependencies, lifecycle rules, and testing boundaries.
- The [decision record](decisions.md) explains accepted tradeoffs and when to
  revisit them.
- The [roadmap](roadmap.md) records current direction, release requirements,
  and work deferred until a concrete workflow needs it.

## Research and releases

- The [multi-session Logcat design record](logcat-sessions.md) contains the
  Android Studio comparison, current design, limits, and live verification.
- The [release verification record](release-evidence.md) lists the commits,
  environments, integration checks, and published tags behind each release.
- The [provenance inventory](provenance.md) records the source and attribution
  review used for the MIT license.

## Sources of truth

When documents disagree, use each one for its stated subject:

1. Vimdoc defines public behavior and contracts.
2. Architecture defines internal ownership and invariants.
3. Decisions preserve accepted rationale.
4. Tests define executable behavior.
5. The roadmap records current direction, release requirements, and deferred
   work.
6. Implementation shows the current mechanism.

A public behavior change updates vimdoc and tests together. An ownership change
updates architecture. A durable tradeoff updates the decision record. Release
claims require matching evidence in the ledger.
