# Contributing

Android Workbench accepts focused bug fixes, documentation changes, and
features that fit its Android and Gradle scope. Open an issue before starting a
large feature or public API change so its ownership and user workflow can be
settled first.

## Reporting a bug

Run this inside the affected project before opening an issue:

```vim
:checkhealth android_workbench
```

Include:

- The Android Workbench version or exact commit.
- The first line of `nvim --version` and the operating system.
- The exact `:Android` command or picker action that failed.
- The relevant `:checkhealth android_workbench` and `:messages` output.
- Task output from `:Android output`, or the configured runner's output.
- `./gradlew --version` and the Android Gradle Plugin version for discovery or
  build failures.
- `adb version` and the affected line from `adb devices -l` for device or
  Logcat failures.
- The smallest project structure or reproduction that still fails.

Remove signing credentials, device identifiers you do not want to publish,
private repository paths, and proprietary source before attaching output.

### Clean Neovim reproduction

Use a local checkout of the exact Workbench revision:

```sh
nvim --clean \
  --cmd 'set runtimepath^=/absolute/path/to/android-workbench.nvim' \
  /absolute/path/to/android/project
```

Run `:checkhealth android_workbench`, then repeat the failing `:Android`
action. If the problem disappears, reduce the normal configuration until the
conflicting plugin or setting is known.

## Requesting a feature

Describe the Android workflow, what you do today, and why the existing command
or extension point cannot support it. Android Workbench does not own language
servers, formatting, test frameworks, debugging, SDK installation, global
mappings, or general editor policy. The current boundaries and deferred ideas
are recorded in the [architecture](docs/architecture/android-workbench.md) and
[roadmap](docs/roadmap.md).

## Making a change

Read the [documentation map](docs/README.md) before changing public behavior.
Keep each change focused. A bug fix should reproduce the failure first, usually
with a focused contract test. New behavior updates its tests and vimdoc in the
same change.

Use the existing formatting rules and direct process argument lists. Do not add
shell-composed project commands, global mappings, automatic optional-plugin
detection, or dependencies on a personal Neovim configuration.

## Verification

The standalone checks do not load a user's configuration, contact a device, or
evaluate an arbitrary Android project:

```sh
make test
```

Run the formatter check after Lua or runtime changes:

```sh
make test-format
```

After editing `doc/android-workbench.txt`, regenerate help tags and run the
package check:

```sh
nvim --clean --headless '+helptags doc' '+qa'
make test-package
git diff --check
```

The real Gradle and optional-adapter fixtures use the network and local Android
SDK. Run them only when the change affects their boundary:

```sh
make test-integration
```

Their prerequisites and cleanup behavior are documented in
[`tests/integration/gradle/README.md`](tests/integration/gradle/README.md) and
[`tests/integration/adapters/README.md`](tests/integration/adapters/README.md).

## Documentation changes

- `README.md` explains what the plugin is, how to install it, and the shortest
  path to first use.
- `doc/android-workbench.txt` defines user-visible behavior, configuration,
  commands, Lua APIs, and adapter contracts.
- `docs/architecture/android-workbench.md` records internal ownership and
  lifecycle rules.
- `docs/decisions.md` records accepted tradeoffs and their revisit conditions.
- `docs/roadmap.md` records current direction, release requirements, and
  deferred work.
- `CHANGELOG.md` records user-visible changes.

Do not teach consumers to require internal lifecycle or model modules merely
because Lua can reach them. The supported pre-1.0 surface is listed in
`:help android-workbench-api` and `:help android-workbench-setup`.
