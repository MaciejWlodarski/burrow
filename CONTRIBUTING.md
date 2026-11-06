# Contributing to Burrow

Thanks for your interest in Burrow. Bug reports, translations, ideas and pull requests are all welcome. If you are looking for a place to start, see the issues labeled [**good first issue**](https://github.com/MaciejWlodarski/burrow/labels/good%20first%20issue) and [**help wanted**](https://github.com/MaciejWlodarski/burrow/labels/help%20wanted), or the [roadmap](README.md#roadmap). Questions and ideas that are not yet a concrete issue fit in [Discussions](https://github.com/MaciejWlodarski/burrow/discussions).

## Build and run

You need macOS 15 Sequoia or later and the Xcode 16 (or newer) command-line tools: `xcode-select --install`. There is no Xcode project; scripts call `swiftc` directly, and Burrow has no third-party dependencies.

```sh
git clone https://github.com/MaciejWlodarski/burrow.git
cd burrow
zsh scripts/setup_signing.sh   # once: a local signing identity, so permissions survive rebuilds
zsh ./build_app.sh             # builds Burrow.app in the repository folder
open Burrow.app
```

`zsh scripts/update.sh` builds and installs into `/Applications` instead, replacing an installed Burrow. `swift build` is a quick way to check that everything compiles.

Burrow works on real files. While developing, try file operations on disposable folders, not on data you care about.

## Tests

```sh
zsh ./scripts/run_tests.sh          # regression suites and the file-operation harness
python3 scripts/check_localization.py
```

The regression runner compiles the app's models, engines and views with `BURROW_TESTING` and runs them against real temporary files, with an isolated home folder and preferences. `swift test` is not equivalent: `Package.swift` declares executable targets only. A new test is a `runAll()` in `Tests/BurrowTests/` called from `TestRunner.swift`.

CI runs the same checks on macOS 26 and macOS 15 for every pull request and every push to `main`.

## Where things are

| Path | What it holds |
| --- | --- |
| `Sources/Burrow/Views` | SwiftUI views and AppKit bridges: panes, sidebar, toolbar, disk map, sheets |
| `Sources/Burrow/Models` | App and pane state, navigation, sessions, search queries |
| `Sources/Burrow/Engine` | File operations, the disk scanner, the search index, folder sizes, volumes |
| `Sources/BurrowCLI` | The `burrow` command-line tool and its MCP server |
| `Tests/BurrowTests` | Regression suites |
| `Resources` | `Info.plist` and translations (`pl.lproj/Localizable.strings`) |
| `scripts` | Build, test, signing, packaging and release helpers |

The [guide](docs/GUIDE.md) documents behavior, limits and safety checks in detail.

## Conventions

- **Native only.** SwiftUI with AppKit where SwiftUI falls short; no third-party packages.
- **Data safety first.** File operations must never lose data: check that an item is still the one the user chose before changing it, prefer the Trash, keep undo working, and report partial failures.
- **Keep the main thread free.** Disk access, scans and long operations run off the main actor and publish results back.
- **Supported systems.** The minimum is macOS 15. APIs from macOS 26 go behind `#if compiler(>=6.2)` and `if #available(macOS 26.0, *)`, because CI also builds with the older Xcode on macOS 15.
- **View state** uses the `@ViewState` wrapper, like the rest of the code.
- **Text.** English is the source language. Every new string the user sees needs a Polish entry in `Resources/pl.lproj/Localizable.strings`; `check_localization.py` lists missing ones.
- **Look and feel.** Burrow follows Finder and the macOS Human Interface Guidelines. For visible changes, keep to the existing spacing and colors in `FinderUI.swift`.

## Pull requests

- Keep each pull request focused on one change, and explain what it does and why.
- Say how you tested it: macOS version, Apple silicon or Intel, and what you tried by hand.
- For visible changes, add before and after screenshots, in light and dark mode if the look differs.
- Make sure `run_tests.sh` and `check_localization.py` pass.

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).

## Translations

To add a language, copy `Resources/pl.lproj/Localizable.strings` to `Resources/<code>.lproj/`, translate the values (keep the keys and the `%@`, `%lld` placeholders), and add the code to `CFBundleLocalizations` in `Resources/Info.plist`. Run `check_localization.py`, then build and switch the language in **Settings → Language** to check the result.

## Reporting bugs

Use the [bug report form](https://github.com/MaciejWlodarski/burrow/issues/new/choose). Include your macOS version, the Burrow version (**Burrow › About Burrow**) and steps to reproduce. For file-operation problems, describe the source and destination disks (internal, external, network, cloud) and remove private paths from logs.

**Security issues** should not go in public issues. Report them privately through [**Report a vulnerability**](https://github.com/MaciejWlodarski/burrow/security/advisories/new).
