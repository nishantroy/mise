# Mise design

Direction: **warm kitchen**. The look is a cream paper background, rounded cards, a terracotta accent and an olive secondary colour, with serif titles. It should feel like a well-used home cookbook, not a stock settings screen. Chrome stays native (iOS 26 `TabView`, `NavigationStack` and its glass bars, sheets, system controls inside forms); the content areas are custom.

All styling lives in `App/Theme/` (`Theme.swift` plus small reusable components). Views use semantic tokens and never hard-code colours, fonts or radii, so a redesign touches one folder.

## Colour tokens

Define them in the asset catalog as colour sets with Any and Dark appearances, and expose them as `Color.mise.*` (or `Theme.Colors.*`).

| Token | Light | Dark | Use |
|---|---|---|---|
| `background` | `#FAF6EF` | `#1C1815` | Screen background (cream paper / warm charcoal) |
| `surface` | `#FFFDF9` | `#262019` | Cards |
| `surfaceSunken` | `#F2EBDF` | `#312A22` | Image placeholders, chips at rest, input fields |
| `ink` | `#2B2420` | `#F3ECE2` | Primary text |
| `inkSecondary` | `#6B5F55` | `#B5A898` | Metadata, captions |
| `divider` | `#E6DCCD` | `#3A3129` | Hairlines, card borders |
| `accent` | `#C2410C` | `#F07A3E` | Primary buttons, tint, selected chips, links |
| `onAccent` | `#FFFFFF` | `#1C1815` | Text and icons on accent fills |
| `herb` | `#5F6F2E` | `#A3B36A` | "From your pantry" badge, "have" state, success |
| `caution` | `#B45309` | `#F2B05E` | "Do you have X?" and missing cards |
| `conflict` | `#B42318` | `#F28B82` | Diet and allergy conflict cards |

Set the app's global tint to `accent`. Paint `background` behind every scroll view (`.scrollContentBackground(.hidden)` + `.background(Color.mise.background)` on lists and forms) so no screen shows system grey. Text on any fill must meet WCAG AA (4.5:1 for body text); check the pairs above when you add new ones.

## Type

- Recipe titles, screen headers, the greeting and onboarding questions use New York serif: `.font(.title2).fontDesign(.serif)` or `.largeTitle` for headers, semibold.
- Everything else uses SF with system text styles (`.body`, `.subheadline`, `.caption`). No fixed point sizes, so Dynamic Type works everywhere.
- Quantities in ingredient lists use `.monospacedDigit()` so fractions line up.

## Shape and spacing

- Spacing scale: 4 / 8 / 12 / 16 / 24 / 32. The screen side gutter is 16.
- Cards: `surface` fill, 16pt continuous corner radius, 16pt padding, a 1px `divider` border, and in light mode only a soft shadow (black, 6% opacity, radius 8, y 2).
- Chips are capsules. At rest: `surfaceSunken` fill with `ink` text. Selected: `accent` fill with `onAccent` text.
- Buttons. Primary: a full-width capsule with `accent` fill, `onAccent` label, at least 50pt tall. Secondary: `accent` text on `surfaceSunken`. Destructive actions use the system red role.
- Minimum tap target is 44×44.

## Components (build in `App/Theme/`)

- `MiseCard`: the container described above.
- `RecipeCard`: image on top (16:10, `AsyncImage`; placeholder is `surfaceSunken` with a fork-and-knife SF Symbol in `inkSecondary`), then a serif title and a "35 min · Chinese" metadata line.
- `Chip` / `ChipGroup`: a wrapping flow layout of selectable chips, used for diet, avoid tags, dislikes, cuisines and the adjust-screen quick chips.
- `PrimaryButton`, `SecondaryButton`.
- `Badge`: a small capsule, e.g. "From your pantry" in `herb` at 15% opacity fill with `herb` text.
- `ReviewCard`: a `MiseCard` with a 4pt leading colour bar (`conflict`, `caution`, or `herb`), an SF Symbol and a title.
- `EmptyState`: an SF Symbol in `accent`, a serif headline, one line of body text and a primary button.

## Screens

- **Recipes:** the header is a serif greeting by time of day ("Good morning", "Good afternoon", "Good evening"), then a vertical stack of `RecipeCard`s on `background`, with search. The import button is in the toolbar.
- **Recipe detail:** a hero image (when there is one), a serif title, a metadata row, and a servings stepper in a card. Ingredients and steps each sit in a card, with steps numbered in accent-coloured circles. History and notes follow. The primary button at the bottom is "I made this".
- **Ingredient check:** one `ReviewCard` per item. Swap options are rows inside the card with a radio selection, the note in `inkSecondary` and the pantry `Badge`. The allergy disclaimer is a caption at the bottom.
- **Onboarding:** one question per page on `background`, with a serif question, chips or controls, a page-dots indicator and a primary Continue button. The pantry quick-pick is a 3-column grid of chips.
- **Pantry:** sections for Have and Missing, each a card listing items, with swipe to move or delete.
- **Settings:** a system `Form` is fine here, with `background` behind it and `accent` tint.

## App icon

A wooden tasting spoon holding tomato soup, with steam, on a cobalt gradient (`#2F66C2` → `#173C7C`). The source is `design/appicon.svg`. It replaced the first placeholder, a cream serif "M" on terracotta.

## Previews

Every view gets light and dark previews. Check at least one screen at the largest accessibility text size.
