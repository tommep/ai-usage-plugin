# Contributing to AI Usage

Please open an issue for a bug or discuss a larger feature before building it.
For a fix, fork the repository and submit a focused pull request to `main`.
Do not include unrelated refactors or dependency additions.

## Build and verify

Use macOS 14+ with a Swift 6 toolchain and macOS SDK.

```sh
swift test
zsh -n scripts/build-app.sh
zsh scripts/build-app.sh
open "build/AI Usage.app" --args --preview
```

The preview uses real local accounts if their CLIs are connected. Closing the
preview leaves the menu bar app running; quit through its More menu. Tests use
fictional provider data and require no account credentials or live requests.
Do not use real credentials, account identifiers, or conversation content in tests.

Describe the bug, the resulting behavior, and how you verified it. For UI changes,
include a screenshot with account-specific information removed. For provider
changes, distinguish fixture tests from live observations and document the CLI
version used. Keep credential access and usage parsing separate from the view.

Preserve these behaviors:

- Unknown, failed, stale, and expired evidence must never appear as zero usage.
- Reset alerts require provider evidence, not just a local clock.
- No model turns or quota-consuming prompts should be sent to fetch usage.
- Tokens must never enter source, preferences, logs, or public issue attachments.
- Network and child-process operations must remain bounded and clean up on quit.
- A provider failure must not hide the other provider's usable result.

## Review and release

Pull requests run macOS build/tests with a read-only workflow token and no signing
credentials. Maintainer review, passing checks, and resolved conversations are
required before a contribution is merged. The repository owner retains admin
bypass for maintenance and recovery. Contributors do not receive direct write
access by submitting a pull request.

Changes are contributed under the repository's MIT license. Accepted changes
appear in the source first. Building, signing, notarizing, and publishing an app
release are separate maintainer actions; pull requests cannot publish a release.

## Architecture

- `Usage.swift`: provider-neutral snapshots, parsing, freshness, and resets.
- `Providers.swift`: CLI discovery and bounded provider transport.
- `UsageStore.swift`: polling, reconnection, and observable UI state.
- `UsageAlerts.swift`: persistent threshold and renewal event logic.
- `SignIn.swift`: official CLI login launcher and completion observation.
- `Preferences.swift` / `SystemSettings.swift`: local preferences and native settings.
- `Panel.swift` / `SettingsView.swift`: compact SwiftUI interface.
- `ProviderArtwork.swift` / `Resources/`: bundled provider icons and menu bar labels.
- `main.swift` / `PopoverLayout.swift`: AppKit menu item and bounded dropdown.

Please use [private security reporting](SECURITY.md) for sensitive findings.
