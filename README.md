# Mise

A personal iPhone recipe app. Import a recipe from a link (or Share from Safari). Mise flags ingredients you might not have, remembers your answers in a pantry, and suggests swaps that use what you already have. After you cook, tell it what you changed and it updates the recipe. Everything runs on the device: Apple's on-device Foundation Models make it conversational where available, and built-in rules do the job when they aren't.

- `PLAN.md`: the v1 spec. `DESIGN.md`: the visual design. `NOTES.md`: decisions, deviations and checks still to do by hand.
- `Packages/RecipeKit`: all the logic (parsing, ingredient catalog, swaps, feedback rules), plain Swift + Foundation, tested with `swift test`.
- `App/`: the SwiftUI app (SwiftData storage). `ShareExtension/`: the Safari share extension. `Widgets/`: the Live Activity for cook-mode timers (AlarmKit countdowns). `MiseUITests/`: XCUITests.

## Requirements

- macOS with Xcode 26 (built with Xcode 26.6) and the iOS 26 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- To run on a phone: an iPhone on iOS 26, and an Apple Developer account (a paid one for TestFlight). Apple Intelligence is optional; without it Mise uses its built-in rules.

## Build and run in the simulator

The Xcode project is generated and not committed:

```sh
xcodegen generate
open Mise.xcodeproj        # pick the "Mise" scheme and an iPhone simulator, then Run
```

From the command line:

```sh
xcodebuild -project Mise.xcodeproj -scheme Mise \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData build
```

Run `xcodegen generate` again whenever you add or remove files or edit `project.yml`.

## Tests

```sh
# Logic (fast, no simulator)
cd Packages/RecipeKit && swift test

# UI tests (onboarding, import, ingredient check, adjust, paste my version, assistant, share queue)
xcodebuild test -project Mise.xcodeproj -scheme Mise \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData
```

UI tests never hit the network for recipes: they launch the app with `-uiTesting -resetData` and serve the HTML fixtures from `Packages/RecipeKit/Tests/RecipeKitTests/Fixtures` through a stub fetcher. Two tests depend on the environment and skip themselves when it doesn't cooperate: `AssistantUITests.testModelPathWhenAvailable` needs the on-device model, and `SafariShareUITests` needs Safari and network access. `ScreenshotTour` only runs when `TEST_RUNNER_MISE_SHOT_DIR` is set.

## Set your team, bundle ID and App Group

The project ships with placeholders: `DEVELOPMENT_TEAM` empty, `BUNDLE_ID_BASE = com.nishantroy.mise`, `APP_GROUP_ID = group.com.nishantroy.mise`. Bundle IDs and App Group IDs are global across Apple accounts, so use your own:

1. Find your Team ID at developer.apple.com → Account → Membership details (10 characters, e.g. `AB12CD34EF`).
2. Edit `project.yml` under `settings: base:`:
   ```yaml
   DEVELOPMENT_TEAM: AB12CD34EF
   BUNDLE_ID_BASE: com.yourname.mise
   APP_GROUP_ID: group.com.yourname.mise
   ```
   The app gets `$(BUNDLE_ID_BASE)`, the share extension `$(BUNDLE_ID_BASE).share` and the timer Live Activity extension `$(BUNDLE_ID_BASE).widgets` (no entitlements). Both entitlements files and both Info.plists (`AppGroupID`) pick up `$(APP_GROUP_ID)`, so these three lines are the only place to change.
3. `xcodegen generate`.

## Run on your iPhone

1. Do the steps above and open `Mise.xcodeproj`.
2. Connect the iPhone (or pair it over Wi-Fi), unlock it, and trust the Mac. On the phone, turn on Developer Mode (Settings → Privacy & Security → Developer Mode) if asked, then restart.
3. In Xcode, select the **Mise** scheme and your iPhone as the destination, then press Run.
4. Signing is automatic: Xcode registers both bundle IDs and the App Group (`group.com.yourname.mise`) for your team. If it reports an App Group or provisioning error, open the Mise and MiseShare targets → Signing & Capabilities, check that the team is set, and press "Try Again". If needed, add the App Group by hand at developer.apple.com → Identifiers → App Groups and enable it on both App IDs.
5. With a free Personal Team, the app expires after 7 days and App Groups may not be available. A paid account avoids both.
6. To use the share extension: in Safari, tap Share (on iOS 26 it's in the "…" More menu), scroll the app row to the end, tap More, and add Mise. Then Share → Mise.

## TestFlight

1. Paid Apple Developer account. Note the Team ID.
2. In `project.yml` set `DEVELOPMENT_TEAM`, `BUNDLE_ID_BASE` (e.g. `com.yourname.mise`) and `APP_GROUP_ID` (`group.com.yourname.mise`), then run `xcodegen generate`.
3. With automatic signing on, Xcode registers both bundle IDs and the App Group when you build to a device. If it doesn't, add them at developer.apple.com → Identifiers.
4. App Store Connect → Apps → + → New App: iOS, pick the bundle ID, any SKU.
5. In Xcode, select "Any iOS Device (arm64)" → Product → Archive → Distribute App → App Store Connect → Upload. Bump `CURRENT_PROJECT_VERSION` in `project.yml` (and run `xcodegen generate`) for every upload.
6. In App Store Connect → TestFlight, wait for processing. The export compliance question is already answered by `ITSAppUsesNonExemptEncryption = NO` in both Info.plists.
7. Internal testing: add yourself and install through the TestFlight app. For friends without App Store Connect access, create an External group, add their emails or make a public link, and submit the build for Beta App Review (usually about a day the first time).

The app icon is a wooden tasting spoon of tomato soup on a cobalt background. Its source is `design/appicon.svg`; the exported `App/Assets.xcassets/AppIcon.appiconset/AppIcon.png` is 1024×1024 with no transparency.

## Privacy

No accounts, no backend, no analytics. Recipe pages are fetched directly from the site you link. The Foundation Models assistant runs on the device. Both targets ship a `PrivacyInfo.xcprivacy` declaring UserDefaults use (CA92.1 for the app's own defaults, 1C8F.1 for the App Group). The widget extension uses no required-reason APIs.
