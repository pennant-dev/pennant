# Contributing to Pennant

Thanks for helping. Bug reports, fixes, skills and design ideas are all welcome.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on the approach.
- Read [docs/SPEC.md](docs/SPEC.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/DESIGN.md](docs/DESIGN.md). [docs/DECISIONS.md](docs/DECISIONS.md) explains why things are the way they are.
- Be kind; the [code of conduct](CODE_OF_CONDUCT.md) applies everywhere.

## Building and testing

```sh
swift build
swift test --skip LiveInferenceTests        # the suite that needs no model or network
Scripts/generate-project.sh                  # Pennant.xcodeproj for the Mac and iPhone apps
swift run pennant-host --root /tmp/pennant-dev --port 7400   # a host of its own, beside the one the app runs
```

`LiveInferenceTests` talk to a real model; run them against a local Ollama when you change inference code.

## What a good change looks like

- **Tests with the change.** Runtime, store, protocol and migration changes need tests; the host has an in-process test harness for most of it.
- **The runtime rules hold.** The host stays authoritative. Uncertain actions are reconciled rather than retried. Agents look again after a takeover. Inferred memory never overwrites what the user said. Outward actions go through approval cards.
- **Generic in Swift, specific in skills.** Site- or company-specific logic belongs in a skill's scripts, not in the app.
- **The design system.** Use the `PennantTheme` tokens and the controls in `Controls.swift`; choices come before free text. Set type with `Font.zoomed(.callout)` rather than `.callout`, so View › Zoom reaches it.
- **Plain words.** Write interface text and docs for the person using Pennant, not for the code.

## Pull requests

Keep them focused, explain the why in the description, and note anything you couldn't test (for example a macOS permission prompt). By contributing you agree that your work is licensed under the [Apache License 2.0](LICENSE).
