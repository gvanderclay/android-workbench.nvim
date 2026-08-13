# Android Workbench

Android Workbench is a focused Neovim workbench for everyday Android
development. It discovers Android application variants through a project's own
Gradle wrapper, remembers an application, variant, and device per project, and
coordinates build, install, launch, stop, emulator, Gradle-task, build-problem,
and Logcat workflows.

> [!IMPORTANT]
> Pre-1.0 tags are published as GitHub prereleases. Android Workbench has not
> been submitted to a plugin registry, and pre-1.0 APIs may still change under
> the `0.x` policy below.

## Design boundary

Workbench owns Android and Gradle orchestration. It does not own Kotlin or Java
language tooling, formatting, test frameworks, DAP, autosave, file watching,
KMP/iOS, SDK installation, or general editor behavior.

The plugin provides native defaults and explicit adapter ports. Telescope and
Overseer are optional integrations, not required dependencies. Workbench does
not define keymaps, WhichKey entries, global picker overrides, or automatic
Trouble behavior. A consuming Neovim configuration chooses those policies.

The durable ownership and lifecycle contracts are documented in
[the architecture guide](docs/architecture/android-workbench.md). The reasons
behind the current shape live in [the decision record](docs/decisions.md).

## Current capabilities

- Trusted, bounded Gradle discovery for Android application variants and
  registered task names, including composite-build identity.
- Root-isolated application, variant, physical-device, and AVD selection.
- Exact Build, Run, application Stop, and arbitrary registered Gradle-task
  execution without shell-composed commands.
- A project-local, state-aware AVD manager plus bounded emulator start, Cold
  Boot, readiness, and exact stop.
- Independent app/device Logcat sessions with retained hidden history, session
  switching, pause, follow, filtering, clearing, and source navigation.
- Bounded Kotlin, Java, Android Lint, AAPT, and AGP problem parsing with a
  root-owned quickfix sink and an optional diagnostic projection.
- A configuration-only `setup()` and a lazy `:Android` command surface.

This list describes implemented breadth, not a public stability promise. The
intentional pre-1.0 facade and module boundary is documented in
`:help android-workbench-api`. Supported and experimental replacement ports are
documented in `:help android-workbench-setup`; compatibility follows the `0.x`
policy below.

## Requirements and current support evidence

Verified host evidence covers Neovim 0.12.4 on macOS and Linux. Individual
workflows additionally require:

- Command, help, and health require Neovim 0.12.4.
- Discovery, Build, Run, and Gradle tasks require an executable Unix `gradlew`,
  the project's compatible JDK, and its normal Android/Gradle inputs.
- Device actions and Logcat require `adb` on `PATH`, or explicitly injected
  services.
- AVD lifecycle requires Android Emulator and ADB on `PATH`, or an injected
  semantic emulator service.
- Telescope selection requires Telescope only when that adapter is selected.
- Overseer execution requires Overseer only when that adapter is selected.

The real fixture passes Gradle 7.3.3 with AGP 7.1.3 and the chosen current pair,
Gradle 9.1.0 with AGP 9.0.1, using Java 17. Other Gradle/AGP pairs are
unverified. The optional-adapter smoke passes Telescope
`427b576c16792edad01a92b89721d923c19ad60f`, Plenary
`74b06c6c75e4eeb3108ec01852001636d85a932b`, and Overseer
`a93d9f6d6defdac4bcd6d2c8ba988650e42e0a0e`; other revisions are unverified.

Windows is not currently supported because Workbench executes an executable
Unix `gradlew` and has no tested `gradlew.bat` path. Other Unix-like hosts are
also unverified.

## Development installation

A Neovim 0.12 consumer using `vim.pack` can add the repository during startup
and configure the native defaults:

```lua
vim.pack.add {
  'https://github.com/gvanderclay/android-workbench.nvim',
}

require('android_workbench').setup {}
```

`setup()` only validates and stores configuration. It does not resolve a
project, prompt for trust, create a session, query ADB, enumerate AVDs, or run
Gradle. The first action constructs the application lazily.

A consuming configuration may compose optional adapters explicitly without
changing Workbench's defaults:

```lua
require('android_workbench').setup {
  ports = {
    picker = require('android_workbench.integrations.telescope').new(),
    problems = require('android_workbench.integrations.diagnostics').new {
      sink = require('android_workbench.integrations.quickfix').new {
        open_on_failure = true,
        close_on_success = true,
      },
    },
    runner = require('android_workbench.integrations.overseer').new(),
  },
}
```

That snippet is a consumer recipe, not package policy. Mappings and provider
presentation belong in the consuming configuration.

## Commands and help

Run `:Android` for the contextual action menu. The command also accepts:

- `status` and `refresh`
- `target app`, `target variant`, and `target device`
- `emulator` for the state-aware manager, plus `emulator start` and
  `emulator stop`
- `build`, `run`, `stop`, `gradle`, and `output`
- `logcat`, `logcat sessions`, `logcat stop`, `logcat stop all`, and `cancel`

Use `:help android-workbench` for the complete command and configuration
reference, and `:checkhealth android_workbench` for local prerequisites.

Gradle discovery and executable Gradle actions run project-controlled code.
Workbench prompts through Neovim's trust mechanism immediately before each
such execution. Device, emulator, application-stop, and Logcat operations do
not evaluate Gradle build logic.

## Development

Run the complete standalone verification from the repository root:

```sh
make test
```

The focused lanes are:

```sh
make test-contract
make test-package
make test-format
```

The contract lane runs the isolated behavioral suites. The package lane checks
clean startup, command and setup laziness, help, health, and the bundled Gradle
asset without loading another user configuration. See
[the architecture guide](docs/architecture/android-workbench.md) for design
constraints and [the roadmap](docs/roadmap.md) for completed milestones and
deferred work.

The explicit network/SDK integration gates stay outside `make test`:

```sh
make test-integration
```

They run the shipped provider and decoder against the recorded Gradle/AGP
floor and current pair, then load the pinned Telescope and Overseer adapters.
See [the release-evidence ledger](docs/release-evidence.md) for exact revisions
and recorded results.

## Release status

`v0.1.0` is the first tagged pre-1.0 release. Tagged releases and their notes
are published on GitHub. Their runtime, API, licensing, CI, real Gradle/AGP,
optional-adapter, and daily-use checks are recorded in the
[release-evidence ledger](docs/release-evidence.md). The plugin has not been
submitted to a registry. Changes not yet assigned to a release remain under
`Unreleased` in the [changelog](CHANGELOG.md).

## 0.x change policy

The documented facade and supported replacement ports are the intended `0.x`
compatibility surface. A minor `0.x` release may still make a breaking change;
user-visible and compatibility changes are recorded in [the changelog](CHANGELOG.md).
Internal modules and ports labeled experimental may change without a
compatibility bridge.

## License

Android Workbench is available under the [MIT License](LICENSE). The recorded
source and attribution review is in [the provenance inventory](docs/provenance.md).
