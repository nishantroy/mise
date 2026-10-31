# Mise: build plan

This is the v1 spec. Work through the milestones in order. Finish each milestone's acceptance checks before starting the next, and commit at the end of each one. When an Apple API detail here doesn't match the SDK you have, trust the SDK and note the change in `NOTES.md`.

**Read "Amendments" at the bottom first. They override the body where they conflict.**

## Goal

An iPhone app for the owner and a few friends (TestFlight only) that:

1. Asks a few preference questions at first launch.
2. Imports a recipe from a URL (paste, or Share from Safari).
3. Flags ingredients the user may not have (e.g. Shaoxing wine), asks once, remembers the answer in a pantry, and offers swaps that favour what they have.
4. Updates a saved recipe after the user says what they changed or how it went.

Everything runs on device. No backend, no API keys. Apple's Foundation Models framework makes it conversational where available; deterministic rules do the job when it isn't.

## Non-goals for v1

- Cooking-time Q&A ("my curry is too dry"), meal planning, shopping lists, nutrition
- Sync between devices, accounts, sharing recipes
- Cloud LLMs (but keep the seam so one can be added later)

## Tech choices

| Area | Choice |
|---|---|
| Target | iOS 26.0, iPhone only, Xcode 26 |
| UI | SwiftUI, `NavigationStack`, `TabView` |
| Storage | SwiftData |
| Logic | Local Swift package `RecipeKit`, pure Swift + Foundation, no UIKit or SwiftData imports, so it's unit testable with `swift test` |
| AI | `FoundationModels` (`SystemLanguageModel`, `LanguageModelSession`, `@Generable`), behind a `RecipeAssistant` protocol |
| Project file | XcodeGen (`project.yml`), so the `.xcodeproj` is generated, not hand-edited |
| Share sheet | Share Extension + App Group queue |

## Folder layout (at the repo root)

```
project.yml                  # XcodeGen spec
README.md                    # build + TestFlight steps
NOTES.md                     # decisions and deviations from this plan
App/
  MiseApp.swift              # @main, ModelContainer, onboarding gate, pending-import pickup
  Info.plist / Mise.entitlements
  Models/                    # SwiftData @Model classes
    SavedRecipe.swift
    PantryEntry.swift
    UserProfile.swift
  Services/
    RecipeFetcher.swift      # URLSession → HTML string
    AssistantProvider.swift  # picks FoundationModels or rules
    FoundationModelsAssistant.swift
    PendingImports.swift     # App Group UserDefaults queue
  Views/
    Onboarding/OnboardingFlow.swift
    Recipes/RecipeListView.swift
    Recipes/ImportView.swift
    Recipes/IngredientCheckView.swift
    Recipes/RecipeDetailView.swift
    Recipes/AdjustRecipeView.swift
    Pantry/PantryView.swift
    Settings/SettingsView.swift
ShareExtension/
  ShareViewController.swift
  Info.plist / MiseShare.entitlements
Packages/RecipeKit/
  Package.swift
  Sources/RecipeKit/
    Model/Recipe.swift, Ingredient.swift, RecipeEdit.swift, UserPreferences.swift, Pantry.swift
    Import/RecipeImporter.swift, JSONLDRecipeParser.swift, TextRecipeParser.swift,
           IngredientLineParser.swift, HTMLText.swift, ISODuration.swift
    Catalog/IngredientCatalog.swift
    Swaps/SwapEngine.swift, IngredientReview.swift
    Adjust/FeedbackParser.swift
    Assistant/RecipeAssistant.swift, RuleBasedAssistant.swift
    Resources/ingredients.json, swaps.json
  Tests/RecipeKitTests/
    Fixtures/*.html          # saved pages from 4–5 real recipe sites
    *Tests.swift
```

## Core types (RecipeKit)

All value types, `Codable`, `Hashable`, `Sendable`.

```swift
public struct Recipe {
    var title: String
    var sourceURL: URL?
    var imageURL: URL?
    var servings: Int?
    var totalMinutes: Int?
    var cuisine: String?
    var ingredients: [Ingredient]
    var steps: [String]
    var notes: [String]
}

public struct Ingredient: Identifiable {
    let id: UUID
    var raw: String          // original line, for display fallback
    var quantity: Double?    // 1.5
    var unit: String?        // "tbsp"
    var name: String         // "shaoxing wine"
    var note: String?        // "or dry sherry"
    var catalogID: String?   // matched catalog entry, if any
}

public enum RecipeEdit {
    case replaceIngredient(id: UUID, with: [Ingredient], reason: String?)
    case scaleIngredient(id: UUID, factor: Double)
    case removeIngredient(id: UUID)
    case addIngredient(Ingredient)
    case updateStep(index: Int, text: String)
    case addNote(String)
}
// Recipe.applying(_ edits: [RecipeEdit]) -> Recipe   (pure)
// RecipeEdit.summary(in: Recipe) -> String           ("Swapped Shaoxing wine for dry sherry")

public struct UserPreferences {
    var diet: Diet                 // .omnivore, .pescatarian, .vegetarian, .vegan
    var avoid: Set<AvoidTag>       // .gluten, .dairy, .egg, .nuts, .peanuts, .shellfish, .pork, .beef, .alcohol, .soy
    var dislikes: [String]         // free text, matched against catalog aliases
    var spiceLevel: Int            // 0 mild … 4 very hot
    var cuisines: [String]
    var weeknightMinutes: Int?
    var servings: Int              // household size
}

public struct PantrySnapshot {
    var have: Set<String>          // catalog IDs (or normalized names if no catalog match)
    var missing: Set<String>
}
```

The edit list is the hinge of the design. Both the rule engine and the model produce `[RecipeEdit]`. The UI shows the proposed edits, the user unticks any they don't want, and only then is anything applied and saved.

## Bundled data

`ingredients.json`, ~150 entries:

```json
{ "id": "shaoxing-wine",
  "names": ["shaoxing wine", "shao xing wine", "chinese cooking wine", "huangjiu"],
  "commonness": "specialty",          // staple | common | specialty | rare
  "category": "condiment",
  "tags": ["alcohol"] }               // meat, pork, beef, poultry, fish, shellfish, dairy, egg,
                                      // honey, gluten, nuts, peanuts, soy, alcohol, spicy
```

Seed it across cuisines the owner cooks (Indian, Chinese, Japanese, Korean, Thai, Italian, Mexican, Middle Eastern). Rough guide: staples (salt, oil, sugar, flour, garlic, onion, eggs, butter, pepper), common (soy sauce, lemons, stock, canned tomatoes, cumin, paprika, honey, vinegar, rice, pasta), specialty (fish sauce, mirin, Shaoxing wine, gochujang, tahini, garam masala, miso, sesame oil, coconut milk, oyster sauce), rare (asafoetida, black cardamom, makrut lime leaves, galangal, Sichuan peppercorns, kasuri methi, amchur, kombu, pandan). Include compound names that must win over shorter ones ("garlic powder" vs "garlic", "dark soy sauce" vs "soy sauce", "toasted sesame oil" vs "oil").

`swaps.json`, ~60 entries:

```json
{ "for": "shaoxing-wine",
  "options": [
    { "use": [{ "id": "dry-sherry", "ratio": 1 }], "quality": "great", "note": "Closest match" },
    { "use": [{ "id": "mirin", "ratio": 1 }], "quality": "good", "note": "Sweeter, so cut any sugar a little" },
    { "use": [{ "id": "chicken-stock", "ratio": 1 }], "quality": "ok", "note": "Keeps the liquid, loses the wine flavour" },
    { "use": [], "quality": "ok", "note": "Leave it out" } ] }
```

A component may give `"amount": "1 tbsp per cup"` instead of `ratio` (e.g. buttermilk = milk + lemon juice); then the new ingredient has no quantity and the amount goes in its text.

## Key logic

**Import** (`RecipeImporter.parse(html:url:) -> Recipe?`)
1. Find every `<script type="application/ld+json">` block. Decode with `JSONSerialization`. Handle a top-level object, an array, and `@graph`. Pick the node whose `@type` is `"Recipe"` or an array containing it.
2. Map `name`, `recipeIngredient`, `recipeYield` (string, number or array; take the first integer), `totalTime` / `cookTime` + `prepTime` (ISO 8601 durations like `PT1H30M`), `image` (string, object with `url`, or array), `recipeCuisine`, `recipeInstructions` (string, `[String]`, `[HowToStep]`, `[HowToSection]` with `itemListElement`).
3. Decode HTML entities and strip tags in every string.
4. Fallback when there's no JSON-LD: convert HTML to text lines, take the title from `og:title` or `<title>`, collect lines under an "Ingredients" heading until an "Instructions / Directions / Method / Steps" heading, then steps until the next heading. Return nil if either list is empty.
5. Parse each ingredient line with `IngredientLineParser`: quantities (`2`, `1 1/2`, `½`, `1-2` takes the upper), units (tsp, tbsp, cup, g, kg, ml, l, oz, lb, clove, can, pinch, with plural and long forms), parenthetical and comma notes ("finely chopped"), then catalog matching on the remaining name.

**Catalog matching**: lowercase, strip punctuation and prep words (chopped, minced, fresh, large, finely…), then the longest catalog alias that appears as whole words wins.

**Ingredient check** (`SwapEngine.review(recipe:pantry:prefs:) -> [ReviewItem]`). For each ingredient, in this order:
- Conflicts with diet or `avoid` (via tags): always flag, with swaps.
- Matches a dislike: flag, with swaps or "leave it out".
- In `pantry.missing`: flag as missing, with swaps, no question.
- In `pantry.have`: fine.
- Commonness is specialty or rare: flag as "Do you have X?".
- Otherwise (staple, common, or not in the catalog): assume they have it.
- Spicy-tagged ingredient and `spiceLevel <= 1`: suggest scaling by 0.5.

**Swap ranking**: score = quality (great 3, good 2, ok 1) + 3 if every component is in `pantry.have`, + 1 if every component is staple or common and none is missing. Drop options with a component in `pantry.missing`, or one that conflicts with diet, avoid tags or dislikes. Return the top 3.

**Applying a swap**: replace the ingredient (quantity × ratio, same unit) and rewrite step text, replacing the old name and its aliases (whole word, case-insensitive) with the new name(s) joined by " and ".

**Feedback parsing** (`FeedbackParser.edits(from:recipe:) -> [RecipeEdit]`, the rule fallback). Split on sentence and clause boundaries, then match:
- "used X instead of Y", "replaced Y with X", "subbed X for Y" → replace
- "skipped / left out / omitted / didn't use / no X" → remove
- "added / threw in X" → add
- "less / cut back on X", "too much X" → scale 0.75; "half the X" → 0.5; "more / extra X", "not enough X" → 1.25; "double the X" → 2
- "too salty" → scale salt and soy sauce 0.75; "too spicy / hot" → scale spicy-tagged 0.5; "not spicy enough / bland" → spicy 1.5; "too sweet" → sugar and honey 0.75
- "needed / cooked N more minutes" → note "Needed about N more minutes than written"
- Anything unmatched → keep the sentence as a note, so feedback is never lost.

Match X to recipe ingredients by catalog ID first, then word overlap.

## Assistant layer

```swift
public protocol RecipeAssistant: Sendable {
    var displayName: String { get }
    func proposeEdits(recipe: Recipe, feedback: String, prefs: UserPreferences) async throws -> [RecipeEdit]
    func suggestSwaps(for ingredient: Ingredient, in recipe: Recipe,
                      pantry: PantrySnapshot, prefs: UserPreferences) async throws -> [SwapSuggestion]
}
```

- `RuleBasedAssistant` (RecipeKit): `FeedbackParser` + `SwapEngine`.
- `FoundationModelsAssistant` (app target):
  - Check `SystemLanguageModel.default.availability`. If it isn't `.available` (device not eligible, Apple Intelligence off, model still downloading), use the rules.
  - `proposeEdits`: one `LanguageModelSession` with instructions describing the recipe format and the allowed edit kinds. Ask for a `@Generable` `EditPlan { edits: [GeneratedEdit] }`, where `GeneratedEdit` has `kind` (a `@Generable` enum: replace, scale, remove, add, note), `ingredient`, `replacement`, `factor`, `text`. Prefer non-optional fields with empty or 1.0 defaults. Map names back to ingredient IDs with the same matcher as the rules; drop anything that doesn't map. Send the rule engine's edits as hints in the prompt, so the model refines rather than invents.
  - `suggestSwaps`: use the bundled table first. Call the model only when the table has nothing for that ingredient. Ask for up to 3 `@Generable` swaps and pass the pantry list so it favours what's there.
  - Any thrown error (guardrail, context size, decoding) → fall back to the rules silently and log it.
- `AssistantProvider` returns the model-backed assistant when it's available and the user hasn't turned it off in Settings. Adding Claude or another cloud model later means one more conforming type, nothing else.

Keep prompts short. The on-device context window is small, so send ingredients and steps, not page HTML.

## SwiftData models (app target)

```swift
@Model final class SavedRecipe {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var title: String                 // denormalised for list sorting and search
    var recipeData: Data              // JSON-encoded Recipe (current)
    var originalData: Data            // as imported, for "reset to original"
    var revisionsData: Data           // [RecipeRevision] { date, summary, edits }
    var rating: Int?                  // -1, 0, 1
    var timesCooked: Int
}

@Model final class PantryEntry {
    @Attribute(.unique) var key: String   // catalog ID or normalised name
    var displayName: String
    var status: String                    // "have" | "missing"
    var updatedAt: Date
}

@Model final class UserProfile {          // single row
    var prefsData: Data                   // JSON-encoded UserPreferences
    var onboardingDone: Bool
}
```

Keep the `Recipe` struct as encoded `Data`: it keeps RecipeKit free of SwiftData and avoids flaky nested Codable properties. Give each model computed accessors that encode and decode.

## Milestones

Commit at the end of each. Don't start the next until the checks pass.

### M0. Skeleton
- `project.yml` with two targets: `Mise` (app) and `MiseShare` (app extension, embedded), plus the local package. Build settings `BUNDLE_ID_BASE` (app = `$(BUNDLE_ID_BASE)`, extension = `$(BUNDLE_ID_BASE).share`), `APP_GROUP_ID`, `DEVELOPMENT_TEAM`, `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`. Both entitlements files list `$(APP_GROUP_ID)`; both Info.plists carry `AppGroupID = $(APP_GROUP_ID)` so code can read it. Set `ITSAppUsesNonExemptEncryption = NO`.
- Empty `RecipeKit` package with one passing test.
- **Check:** `xcodegen generate` works, the app builds and runs in the iOS 26 simulator, and `swift test` passes in `Packages/RecipeKit`.

### M1. RecipeKit models and import
- Core types, `IngredientLineParser`, `ISODuration`, `HTMLText`, `JSONLDRecipeParser`, `TextRecipeParser`, `RecipeImporter`.
- Save 4–5 real recipe pages as fixtures (e.g. Serious Eats, NYT Cooking public page, BBC Good Food, an Indian food blog, one without JSON-LD).
- **Check:** tests cover each fixture (title, ingredient count, step count, servings, time); ingredient-line cases (`1 ½ cups flour`, `2-3 cloves garlic, minced`, `Salt to taste`, `1 (14 oz) can coconut milk`); `@graph`; `HowToSection`; entity decoding.

### M2. Catalog, pantry and swaps
- `ingredients.json`, `swaps.json`, `IngredientCatalog`, `SwapEngine`, `Recipe.applying(_:)`.
- **Check:** tests for longest-alias matching; the review order above (conflict beats pantry; missing skips the question; common is assumed); ranking prefers pantry items; vegetarian drops chicken stock and suggests vegetable stock; applying a swap rewrites step text. A test also loads both JSON files and asserts every swap `id` exists in the catalog.

### M3. Feedback edits
- `FeedbackParser`, `RuleBasedAssistant`, `RecipeEdit.summary`.
- **Check:** one test per pattern above, plus a mixed sentence ("Used chicken thighs instead of breast and it was too salty, needed 10 more minutes") giving 3 edits, and unmatched text becoming a note.

### M4. App data and onboarding
- SwiftData models, `ModelContainer` in `MiseApp`, onboarding flow:
  1. Diet and avoid list
  2. Dislikes (free text chips) and spice level
  3. Cuisines, weeknight time, household size
  4. Pantry quick-pick: a grid of ~30 common and specialty items to tick as "have"
- Root view shows onboarding until `onboardingDone`, then the tabs: Recipes, Pantry, Settings.
- **Check:** a fresh install shows onboarding, relaunch skips it, and Settings can edit every preference.

### M5. Import and ingredient check
- `ImportView`: paste a URL (prefilled from the clipboard if it holds one) or paste recipe text. `RecipeFetcher` uses a normal Safari user agent and a 15 s timeout. Show a clear error when parsing fails.
- `IngredientCheckView` (after import, and from a recipe's menu): one card per review item. "Do you have X?" offers Yes and No; Yes writes `have`, No writes `missing` and reveals swaps. Conflict and missing cards show swaps straight away. Each swap row shows its note and a "from your pantry" badge. Keep original is always an option.
- Save creates a `SavedRecipe` with the swaps applied and recorded as revision 1.
- **Check:** import a Shaoxing wine recipe → asked once → answer No → pick sherry → saved recipe and steps show sherry. Import a second recipe with Shaoxing wine → no question, swaps shown directly.

### M6. Recipe detail and adjustment
- `RecipeDetailView`: servings stepper (display-only scaling via `Recipe.scaled(to:)`), ingredients, steps, notes, revision history, "Reset to original".
- "I made this" → `AdjustRecipeView`: thumbs up/down, quick chips (Too salty, Too spicy, Too bland, Needed more time, Perfect), a free-text box ("What did you change?"), and a Suggest changes button. The assistant proposes edits, shown as a list of toggles with summaries. Save applies the ticked edits, adds a revision, bumps `timesCooked` and sets the rating.
- **Check:** the mixed feedback sentence from M3 gives 3 proposed edits, unticking one leaves it out, and history shows the revision.

### M7. Foundation Models
- `FoundationModelsAssistant`, `AssistantProvider`, a Settings row showing which assistant is active (and why the model is unavailable, when it is), and a toggle to force rules.
- **Check:** on a device with Apple Intelligence on, M5 and M6 work with the model and produce sensible edits for free-form feedback the rules miss ("it was a bit flat, so I finished it with lime and more fish sauce"). With Apple Intelligence off (or in a simulator without it), the same flows work on rules with no error shown.

### M8. Share Extension
- `ShareViewController` reads the first `public.url` attachment, appends it to an array in `UserDefaults(suiteName: AppGroupID)`, shows "Saved, open Mise to finish", and completes.
- On `scenePhase == .active` the app drains the queue and opens `ImportView` for each URL.
- **Check:** Safari → Share → Mise → open the app → the import screen appears with that URL.

### M9. Polish and ship
- App icon, launch screen, empty states, VoiceOver labels on custom controls, Dynamic Type check.
- README: requirements, `brew install xcodegen`, `xcodegen generate`, setting the team, bundle ID and app group, running tests, TestFlight steps (below).
- **Check:** archive succeeds and the build is installed via TestFlight on the owner's phone.

## Testing approach

- RecipeKit holds all logic and has no Apple-only imports, so `swift test` runs it fast. Aim for full coverage of parser, matcher, swap engine and feedback parser branches.
- HTML fixtures are checked in. Never hit the network in tests.
- The app target gets a few UI tests at most (onboarding gate, import with a stubbed fetcher). Inject `RecipeFetcher` and `RecipeAssistant` via the environment so previews and tests use fakes.
- The model path is verified by hand on device (M7 checks); log prompts and outputs in debug builds.
- SwiftUI previews for every view, using an in-memory `ModelContainer` with sample data.

## TestFlight steps (for the README)

1. Paid Apple Developer account. Note the Team ID.
2. In `project.yml` set `DEVELOPMENT_TEAM`, `BUNDLE_ID_BASE` (e.g. `com.yourname.mise`), `APP_GROUP_ID` (`group.com.yourname.mise`), then `xcodegen generate`.
3. With automatic signing on, Xcode registers both bundle IDs and the App Group when you build to a device. If not, add them at developer.apple.com → Identifiers.
4. App Store Connect → Apps → + New App, iOS, pick the bundle ID, any SKU.
5. Xcode: select "Any iOS Device (arm64)" → Product → Archive → Distribute App → App Store Connect → Upload. Bump `CURRENT_PROJECT_VERSION` for every upload.
6. In App Store Connect → TestFlight, wait for processing and answer the export compliance question (already answered by `ITSAppUsesNonExemptEncryption = NO`).
7. Internal testing: add yourself, install via the TestFlight app. For friends without App Store Connect access, create an External group, add their emails or a public link, and submit the build for Beta App Review (usually about a day the first time).

## Working rules

- Small commits per milestone, with a passing `swift test` before each.
- Don't add third-party dependencies without asking. Everything here is doable with Apple frameworks.
- Keep RecipeKit free of UIKit, SwiftUI, SwiftData and FoundationModels.
- Use the Swift 6 language mode in RecipeKit. If strict concurrency fights SwiftData in the app target, use Swift 5 mode there and note it in `NOTES.md`.
- When something in this plan turns out wrong or awkward, pick the simpler option, keep going, and log it in `NOTES.md`.

## Amendments (agreed with the owner, override the body)

Scope and environment
- Work directly on `main`, one commit per milestone. Do not push.
- Machine: Xcode 26.6, Swift 6.3.3, XcodeGen 2.46.0, iOS 26.5 simulator (use "iPhone 17 Pro"). Build for the simulator only. Leave `DEVELOPMENT_TEAM` empty and use placeholders `BUNDLE_ID_BASE = com.nishantroy.mise`, `APP_GROUP_ID = group.com.nishantroy.mise`; the owner will set a team later for their iPhone.
- M9's TestFlight check is out of scope. M9's check becomes: Release build for simulator succeeds, README documents how to set the team and build to a device, and the TestFlight steps are written.
- Device-only checks (M7 with the real model, M8 from Safari on a phone) can't be done here. Do what's possible in the simulator (M8: drive the queue via a UI test or `simctl openurl`/launch arguments; M7: the rules path, plus the model path if `SystemLanguageModel` reports available in the simulator). List what remains for the owner to verify by hand in `NOTES.md` under "Manual checks".
- Verify M4–M6 checks with XCUITests (onboarding gate, import using a stubbed fetcher fed from a fixture, adjust flow) rather than claiming them by inspection.
- Placeholder app icon: generate a simple 1024×1024 PNG yourself (e.g. a solid colour with a simple glyph, drawn with a small Swift or `sips`-based script). No artwork is coming.
- Fixtures: download 4–5 real recipe pages with `curl` (Safari user agent). If a site blocks you (NYT, Serious Eats often do), pick another site. Include at least one Indian food blog, one page with `@graph`, one with `HowToSection`, and one without JSON-LD. You may trim irrelevant markup to keep files small, but keep the JSON-LD and the structure the parser relies on intact.

Additions
1. `PrivacyInfo.xcprivacy` in both the app and the extension, declaring UserDefaults required-reason API (CA92.1 for the app's own defaults, 1C8F.1 for the App Group suite). Add in M0.
2. Clipboard: don't read `UIPasteboard.general.string` on appear (it triggers the paste prompt). Use `PasteButton`, or check `hasURLs` before reading.
3. SwiftData: define the models inside a `VersionedSchema` (`SchemaV1`) with a `SchemaMigrationPlan` from v1.
4. Ingredient check view shows a short line: "Flags are based on a limited ingredient list; check labels if you have allergies."
5. `Recipe.scaled(to:)` and a quantity formatter (0.5 → ½, 1.25 → 1 ¼, sensible rounding) live in RecipeKit, built and tested in M1.
6. Scaling an ingredient with no quantity ("salt to taste" + "too salty") produces an `addNote` ("Use less salt than last time") instead of a no-op scale.
7. Feedback replacement ("used chicken thighs instead of breast") keeps the original's quantity and unit.
8. "Reset to original" is recorded as a revision; history is not wiped.
9. Swap step rewriting replaces longer aliases first so "soy sauce" never corrupts "dark soy sauce".
10. Define a `RecipeFetching` protocol so the fetcher can be stubbed in previews and UI tests.
11. The "no X" remove pattern must ignore phrases like "no problem", "no changes", "no issues", and only fire when X matches a recipe ingredient.
12. The simulator may expose the host Mac's Apple Intelligence model, so the "force rules" toggle is how the rules-only path is tested; don't rely on the model being absent.
13. No HTTP servers are involved, so the port registry in `/Users/nishantroy/code/AGENTS.md` does not apply.
