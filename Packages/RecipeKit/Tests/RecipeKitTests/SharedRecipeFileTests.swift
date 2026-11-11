import Foundation
import Testing
@testable import RecipeKit

@Suite("Shared recipe file (.mise)")
struct SharedRecipeFileTests {
    static func pepperChicken() -> Recipe {
        Recipe(title: "Pepper Chicken", sourceURL: URL(string: "https://example.com/pepper-chicken"),
               imageURL: URL(string: "https://example.com/pc.jpg"), servings: 4, totalMinutes: 35, cuisine: "Indian",
               ingredients: [
                   Ingredient(raw: "500 g chicken thighs", quantity: 500, unit: "g", name: "chicken thighs", note: "boneless"),
                   Ingredient(raw: "2 tbsp oil", quantity: 2, unit: "tbsp", name: "oil"),
                   Ingredient(raw: "Salt", name: "salt"),
               ],
               steps: ["Marinate the chicken for 30 minutes.", "Fry on high for 10 minutes."],
               notes: ["Use more pepper than you think."],
               timeEstimate: TimeEstimate(totalMinutes: 45, activeMinutes: 15, passiveMinutes: 30, reason: "30 min marinating",
                                          source: .rules, passiveLabel: "marinating"))
    }

    static func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func roundTripKeepsRecipeNotesAndPhoto() throws {
        let photo = SharedRecipeFile.Photo(data: Data(repeating: 7, count: 2_000), type: "public.heic")
        var original = Self.pepperChicken()
        original.title = "Pepper Chicken | Spice Blog"
        let file = SharedRecipeFile(recipe: Self.pepperChicken(), original: original, photo: photo,
                                    sharedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let read = try SharedRecipeFile.read(file.fileData())
        #expect(read == file)
        #expect(read.recipe.notes == ["Use more pepper than you think."])
        #expect(read.recipe.cuisine == "Indian")
        #expect(read.recipe.timeEstimate?.totalMinutes == 45)
        #expect(read.recipe.servings == 4)
        #expect(read.recipe.sourceURL?.absoluteString == "https://example.com/pepper-chicken")
        #expect(read.sourceTitle == "Pepper Chicken | Spice Blog")
        #expect(read.photo == photo)
    }

    @Test func fileHasKindVersionAndNothingPrivate() throws {
        let data = try SharedRecipeFile(recipe: Self.pepperChicken()).fileData()
        let object = try Self.json(data)
        #expect(object["kind"] as? String == "mise.recipe")
        #expect(object["version"] as? Int == 1)
        #expect(Set(object.keys) == ["kind", "version", "recipe", "sharedAt"])
        #expect(object["sourceTitle"] == nil)
    }

    @Test func localImageURLIsDropped() throws {
        var recipe = Self.pepperChicken()
        recipe.imageURL = URL(filePath: "/var/mobile/photo.heic")
        let read = try SharedRecipeFile.read(SharedRecipeFile(recipe: recipe).fileData())
        #expect(read.recipe.imageURL == nil)
    }

    @Test func unknownFutureFieldsAreIgnored() throws {
        var object = try Self.json(SharedRecipeFile(recipe: Self.pepperChicken()).fileData())
        object["sharedBy"] = "Asha"
        object["futureThing"] = ["nested": [1, 2, 3]]
        var recipe = try #require(object["recipe"] as? [String: Any])
        recipe["difficulty"] = "easy"
        object["recipe"] = recipe
        let data = try JSONSerialization.data(withJSONObject: object)
        let read = try SharedRecipeFile.read(data)
        #expect(read.recipe.title == "Pepper Chicken")
        #expect(read.recipe.ingredients.count == 3)
    }

    @Test func newerVersionIsRefused() throws {
        var object = try Self.json(SharedRecipeFile(recipe: Self.pepperChicken()).fileData())
        object["version"] = 2
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: SharedRecipeFile.Failure.newerVersion(2)) { try SharedRecipeFile.read(data) }
    }

    @Test(arguments: [
        "", "not json", "[1,2,3]", "{}", #"{"kind":"something.else","version":1}"#,
        #"{"title":"Pepper Chicken","ingredients":[]}"#,
    ])
    func notARecipeIsRejected(_ text: String) {
        #expect(throws: SharedRecipeFile.Failure.notARecipe) { try SharedRecipeFile.read(Data(text.utf8)) }
    }

    @Test(arguments: [
        #"{"kind":"mise.recipe","version":1}"#,
        #"{"kind":"mise.recipe","version":0,"recipe":{"title":"X","steps":["a"]}}"#,
        #"{"kind":"mise.recipe","version":1,"recipe":{"steps":["a"]}}"#,
        #"{"kind":"mise.recipe","version":1,"recipe":{"title":"   ","steps":["a"]}}"#,
        #"{"kind":"mise.recipe","version":1,"recipe":{"title":"Empty"}}"#,
        #"{"kind":"mise.recipe","version":1,"recipe":{"title":"X","steps":["a"],"servings":-3}}"#,
        #"{"kind":"mise.recipe","version":"one","recipe":{"title":"X","steps":["a"]}}"#,
    ])
    func damagedRecipeIsRejected(_ text: String) {
        #expect(throws: SharedRecipeFile.Failure.damaged) { try SharedRecipeFile.read(Data(text.utf8)) }
    }

    @Test func minimalHandWrittenFileOpens() throws {
        let text = #"{"kind":"mise.recipe","version":1,"recipe":{"title":"Toast","steps":["Toast the bread."]}}"#
        let read = try SharedRecipeFile.read(Data(text.utf8))
        #expect(read.recipe.title == "Toast")
        #expect(read.photo == nil)
    }

    @Test func oversizedFileIsRejectedBeforeParsing() {
        let data = Data(repeating: UInt8(ascii: " "), count: SharedRecipeFile.maxFileBytes + 1)
        #expect(throws: SharedRecipeFile.Failure.tooLarge) { try SharedRecipeFile.read(data) }
    }

    @Test func tooManyStepsOrHugeTextIsDamaged() throws {
        var recipe = Self.pepperChicken()
        recipe.steps = Array(repeating: "Stir.", count: SharedRecipeFile.maxSteps + 1)
        let many = try SharedRecipeFile(recipe: recipe).fileData()
        #expect(throws: SharedRecipeFile.Failure.damaged) { try SharedRecipeFile.read(many) }

        recipe = Self.pepperChicken()
        recipe.notes = [String(repeating: "a", count: SharedRecipeFile.maxTextLength + 1)]
        let long = try SharedRecipeFile(recipe: recipe).fileData()
        #expect(throws: SharedRecipeFile.Failure.damaged) { try SharedRecipeFile.read(long) }
    }

    @Test func oversizedPhotoIsRefusedWhenSendingAndDroppedWhenReceiving() throws {
        let big = SharedRecipeFile.Photo(data: Data(repeating: 1, count: SharedRecipeFile.maxPhotoBytes + 1), type: "public.jpeg")
        let file = SharedRecipeFile(recipe: Self.pepperChicken(), photo: big)
        #expect(throws: SharedRecipeFile.Failure.photoTooLarge) { try file.fileData() }

        // A file written by something else with a big photo still opens, without it.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        #expect(data.count <= SharedRecipeFile.maxFileBytes)
        let read = try SharedRecipeFile.read(data)
        #expect(read.photo == nil)
        #expect(read.recipe.title == "Pepper Chicken")
    }

    @Test func photoOfUnknownTypeIsDropped() throws {
        let odd = SharedRecipeFile.Photo(data: Data([1, 2, 3]), type: "public.executable")
        let read = try SharedRecipeFile.read(SharedRecipeFile(recipe: Self.pepperChicken(), photo: odd).fileData())
        #expect(read.photo == nil)
    }

    @Test func photoAtTheLimitFits() throws {
        let photo = SharedRecipeFile.Photo(data: Data(repeating: 9, count: SharedRecipeFile.maxPhotoBytes), type: "public.heic")
        let data = try SharedRecipeFile(recipe: Self.pepperChicken(), photo: photo).fileData()
        #expect(data.count < SharedRecipeFile.maxFileBytes)
        #expect(try SharedRecipeFile.read(data).photo == photo)
    }

    @Test func fixtureRecipeSizes() throws {
        let html = try Fixture.html("indianhealthyrecipes-chicken-curry")
        let recipe = try #require(RecipeImporter.parse(html: html, url: URL(string: "https://example.com/curry")!))
        let plain = try SharedRecipeFile(recipe: recipe).fileData()
        let withPhoto = try SharedRecipeFile(recipe: recipe, photo: .init(data: Data(count: 250_000), type: "public.heic")).fileData()
        // ~18 ingredients and 13 steps: a few KB; a 250 KB photo adds its base64 (×4/3).
        #expect(plain.count < 20_000)
        #expect(withPhoto.count < plain.count + 340_000)
        print("Chicken curry .mise: \(plain.count) bytes; with a 250 KB photo: \(withPhoto.count) bytes")
    }

    @Test(arguments: [
        ("Pepper Chicken", "Pepper Chicken.mise"),
        ("Dal / Tadka: the \"best\"", "Dal Tadka the best.mise"),
        ("..hidden", "hidden.mise"),
        ("  \n ", "Recipe.mise"),
    ])
    func fileNames(_ title: String, _ expected: String) {
        #expect(SharedRecipeFile.fileName(for: title) == expected)
    }

    @Test func plainTextReadsLikeARecipe() {
        let text = SharedRecipeFile(recipe: Self.pepperChicken()).plainText
        #expect(text == """
        Pepper Chicken
        Serves 4 · 35 min · Indian

        INGREDIENTS
        ☐ 500 g chicken thighs, boneless
        ☐ 2 tbsp oil
        ☐ salt

        PREP FIRST
        ☐ Start early: marinate the chicken (30 min)

        STEPS
        1. Marinate the chicken for 30 minutes.

        2. Fry on high for 10 minutes.

        NOTES
        • Use more pepper than you think.

        Source: https://example.com/pepper-chicken
        Made with Mise
        """)
    }

    @Test func plainTextPrepListsChoppingAndMixing() {
        let recipe = Recipe(title: "Stir Fry", servings: 2, ingredients: [
            Ingredient(raw: "1 onion", quantity: 1, name: "onion", note: "thinly sliced"),
            Ingredient(raw: "2 cloves garlic", quantity: 2, unit: "cloves", name: "garlic", note: "minced"),
            Ingredient(raw: "2 tbsp soy sauce", quantity: 2, unit: "tbsp", name: "soy sauce"),
            Ingredient(raw: "1 tbsp honey", quantity: 1, unit: "tbsp", name: "honey"),
            Ingredient(raw: "300 g beef", quantity: 300, unit: "g", name: "beef"),
        ], steps: ["Mix the soy sauce and honey in a small bowl.", "Marinate the beef in half the sauce for 20 minutes.",
                   "Heat a wok and fry the onion and garlic for 2 minutes.", "Add the beef and the rest of the sauce; cook 5 minutes."])
        let text = SharedRecipeFile.plainText(for: recipe)
        #expect(text.contains("""
        PREP FIRST
        ☐ Start early: marinate the beef (20 min)
        ☐ Thinly slice 1 onion
        ☐ Mince 2 cloves garlic
        ☐ Mix 2 tbsp soy sauce and 1 tbsp honey

        STEPS
        """))
    }

    @Test func plainTextWithoutOptionalParts() {
        let text = SharedRecipeFile.plainText(for: Recipe(title: "Toast", steps: ["Toast the bread."]))
        #expect(text == "Toast\n\nSTEPS\n1. Toast the bread.\n\nMade with Mise")
    }
}
