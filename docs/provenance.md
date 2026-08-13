# Provenance

This inventory covers the Android Workbench repository as of 2026-08-11. It
records the evidence used to select the repository license; it is not a claim
about external programs used at runtime.

## Repository material

| Material | Recorded origin | Attribution result |
| --- | --- | --- |
| Lua runtime and plugin entry | Developed in the author's Neovim configuration on 2026-08-10 and 2026-08-11, then moved into this repository | No third-party notice found |
| Contract tests and package smoke | Developed beside the runtime, then moved and extended here | No third-party notice found |
| Vimdoc and repository design documents | Developed beside the runtime or added during the standalone extraction | No third-party notice found |
| Bundled Gradle init script | Developed with the original trusted project-discovery implementation, then moved with the runtime | No third-party notice found |
| Build, formatting, and CI files | Added during the standalone extraction | No third-party notice found |

The original source history and every commit in the standalone repository
record Gage Vander Clay as the author. Repository-wide searches found no
copyright, SPDX, license, copied/adapted-source, vendoring, or upstream
attribution notice in the inventoried source. A comparison of distinctive
Workbench identifiers against locally checked-out copies of
`android-nvim`, `android-nvim-plugin`, `android.nvim`, `astudio.nvim`, and
`droid-nvim` repositories found no matching implementation.

The repository does not distribute Neovim, Gradle, the Android SDK, Telescope,
or Overseer. Calling their public APIs or documenting optional integration does
not copy those projects into this package.

## Result

The repository is licensed under the [MIT License](../LICENSE), using the
standard `MIT` text published by
[SPDX](https://spdx.org/licenses/MIT). Distribution must retain the copyright
and permission notice in the license. The inventory found no additional
attribution obligation, so this repository does not need a `NOTICE` file.

The history and text searches above establish recorded repository provenance;
they cannot independently prove that no unrecorded external source was ever
consulted. Any later copied, adapted, generated, or vendored material must be
reviewed and added to this inventory before distribution.
