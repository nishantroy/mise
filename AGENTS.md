# Mise: agent rules

Shared rules for every project are in `/Users/nishantroy/code/AGENTS.md`. These are stricter, Mise-only rules.

## Never use the iOS Simulator unless the owner asks

The owner's Mac has 8 GB of RAM; a booted simulator slows it to a crawl. Unless the owner explicitly asks in this conversation:

- Don't boot or open a simulator (`xcrun simctl boot`, `open -a Simulator`).
- Don't run anything that launches one: `xcodebuild test` with a `platform=iOS Simulator` destination, UI tests (`MiseUITests`), `simctl install`/`launch`.
- Allowed: `swift test` (RecipeKit), `xcodebuild test -scheme MiseModelTests -destination platform=macOS`, `xcodebuild build` and `build-for-testing` (they compile without booting a simulator), and installing on the owner's iPhone with `devicectl`.
- Verify UI changes on the owner's iPhone instead, or describe what the owner should check.
