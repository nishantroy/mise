import Foundation

/// A recipe shared with a friend as a `.mise` file (JSON). It carries the sharer's current
/// version (with notes, cuisine, time estimate, servings and source link) and optionally their
/// latest cooking photo. Pantry, history, the cooking log and ratings are never included.
///
/// Versioning: `version` is bumped only for changes an older Mise can't read. New optional
/// fields keep the version (older readers ignore unknown keys), so files from a newer build
/// still open where possible; a higher `version` is refused with "update Mise".
public struct SharedRecipeFile: Codable, Sendable, Equatable {
    /// Exported by the app (Info.plist `UTExportedTypeDeclarations`); conforms to public.data.
    public static let typeIdentifier = "com.nishantroy.mise.recipe"
    public static let fileExtension = "mise"
    /// Written into every file so random JSON is rejected.
    public static let kind = "mise.recipe"
    public static let currentVersion = 1

    /// Whole file. A recipe is ~5–15 KB; a photo adds at most `maxPhotoBytes` × 4/3 (base64).
    public static let maxFileBytes = 1_000_000
    /// The sender re-encodes to ≤ 300 KB; a larger photo in a received file is dropped.
    public static let maxPhotoBytes = 400_000
    public static let maxTitleLength = 300
    public static let maxIngredients = 300
    public static let maxSteps = 200
    public static let maxNotes = 100
    /// Any single ingredient line, step or note.
    public static let maxTextLength = 5_000

    public var version: Int
    /// The sharer's current version.
    public var recipe: Recipe
    /// The title the recipe was first saved under (from the page), when the sharer renamed it.
    public var sourceTitle: String?
    public var sharedAt: Date
    public var photo: Photo?

    public struct Photo: Codable, Sendable, Equatable {
        /// Encoded image bytes (base64 in the JSON).
        public var data: Data
        /// "public.heic", "public.jpeg" or "public.png".
        public var type: String

        public static let allowedTypes: Set<String> = ["public.heic", "public.jpeg", "public.png"]

        public init(data: Data, type: String) {
            self.data = data
            self.type = type
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Over `maxFileBytes`.
        case tooLarge
        /// Not JSON, or not a Mise recipe.
        case notARecipe
        /// Written by a newer Mise with a format this build can't read.
        case newerVersion(Int)
        /// A Mise recipe with missing or out-of-range content.
        case damaged
        /// Only when encoding: the photo is over `maxPhotoBytes` (the app downsizes first).
        case photoTooLarge

        public var message: String {
            switch self {
            case .tooLarge: "This file is too big to be a Mise recipe."
            case .notARecipe: "This isn't a Mise recipe file."
            case .newerVersion: "This recipe was shared from a newer version of Mise. Update Mise to open it."
            case .damaged: "This recipe file is damaged or incomplete."
            case .photoTooLarge: "The photo is too large to share."
            }
        }
    }

    /// - Parameters:
    ///   - recipe: the sharer's current version.
    ///   - original: the version first saved, used for `sourceTitle` when its title differs.
    public init(recipe: Recipe, original: Recipe? = nil, photo: Photo? = nil, sharedAt: Date = Date()) {
        version = Self.currentVersion
        var recipe = recipe
        // A local file URL means nothing on another phone.
        if let image = recipe.imageURL, !["http", "https"].contains(image.scheme?.lowercased() ?? "") {
            recipe.imageURL = nil
        }
        self.recipe = recipe
        if let title = original?.title, title != recipe.title { sourceTitle = title } else { sourceTitle = nil }
        self.sharedAt = sharedAt
        self.photo = photo
    }

    // MARK: Coding

    enum CodingKeys: String, CodingKey {
        case kind, version, recipe, sourceTitle, sharedAt, photo
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard (try? c.decode(String.self, forKey: .kind)) == Self.kind else { throw Failure.notARecipe }
        guard let version = try? c.decode(Int.self, forKey: .version), version >= 1 else { throw Failure.damaged }
        guard version <= Self.currentVersion else { throw Failure.newerVersion(version) }
        self.version = version
        guard let recipe = try? c.decode(Recipe.self, forKey: .recipe) else { throw Failure.damaged }
        self.recipe = recipe
        sourceTitle = try? c.decodeIfPresent(String.self, forKey: .sourceTitle)
        sharedAt = (try? c.decodeIfPresent(Date.self, forKey: .sharedAt)) ?? Date()
        // A bad photo shouldn't cost the recipe: it's dropped.
        if let photo = try? c.decodeIfPresent(Photo.self, forKey: .photo),
           !photo.data.isEmpty, photo.data.count <= Self.maxPhotoBytes, Photo.allowedTypes.contains(photo.type) {
            self.photo = photo
        } else {
            photo = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.kind, forKey: .kind)
        try c.encode(version, forKey: .version)
        try c.encode(recipe, forKey: .recipe)
        try c.encodeIfPresent(sourceTitle, forKey: .sourceTitle)
        try c.encode(sharedAt, forKey: .sharedAt)
        try c.encodeIfPresent(photo, forKey: .photo)
    }

    // MARK: File data

    /// The `.mise` file's bytes.
    public func fileData() throws(Failure) -> Data {
        if let photo, photo.data.count > Self.maxPhotoBytes { throw .photoTooLarge }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { throw .damaged }
        guard data.count <= Self.maxFileBytes else { throw .tooLarge }
        return data
    }

    /// Reads a `.mise` file, checking its size and content.
    public static func read(_ data: Data) throws(Failure) -> SharedRecipeFile {
        guard data.count <= maxFileBytes else { throw .tooLarge }
        guard !data.isEmpty else { throw .notARecipe }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file: SharedRecipeFile
        do {
            file = try decoder.decode(SharedRecipeFile.self, from: data)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .notARecipe
        }
        guard file.isWithinLimits else { throw .damaged }
        return file
    }

    var isWithinLimits: Bool {
        let title = recipe.title.trimmed
        guard !title.isEmpty, title.count <= Self.maxTitleLength else { return false }
        guard !recipe.ingredients.isEmpty || !recipe.steps.isEmpty else { return false }
        guard recipe.ingredients.count <= Self.maxIngredients, recipe.steps.count <= Self.maxSteps,
              recipe.notes.count <= Self.maxNotes else { return false }
        let texts = recipe.ingredients.flatMap { [$0.raw, $0.name, $0.note ?? ""] } + recipe.steps + recipe.notes
            + [recipe.cuisine ?? "", sourceTitle ?? ""]
        guard texts.allSatisfy({ $0.count <= Self.maxTextLength }) else { return false }
        if let servings = recipe.servings, !(0...1000).contains(servings) { return false }
        if let minutes = recipe.totalMinutes, !(0...(60 * 24 * 7)).contains(minutes) { return false }
        return true
    }

    /// "Pepper Chicken.mise": the title without characters file systems or Messages dislike.
    public static func fileName(for title: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        var name = title.unicodeScalars.map { banned.contains($0) ? " " : String($0) }.joined()
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        name = String(name.prefix(80)).trimmed
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Recipe" }
        return "\(name).\(fileExtension)"
    }

    // MARK: Plain text

    /// What a friend without Mise reads (Messages, Mail, Notes): title, servings, ingredients,
    /// steps, notes, source link and "Made with Mise".
    public var plainText: String { Self.plainText(for: recipe) }

    /// The recipe as text to paste into Messages or Notes: ingredients and prep as tick-off
    /// lists, prep (from the rule-based `PrepPlanner`) before the steps, steps spaced out.
    public static func plainText(for recipe: Recipe, planner: PrepPlanner = PrepPlanner()) -> String {
        var blocks: [[String]] = []

        var header = [recipe.title.trimmed]
        var meta: [String] = []
        if let servings = recipe.servings, servings > 0 { meta.append("Serves \(servings)") }
        if let time = recipe.displayTime { meta.append((time.isEstimate ? "~" : "") + duration(time.minutes)) }
        if let cuisine = recipe.cuisine?.trimmed, !cuisine.isEmpty { meta.append(cuisine) }
        if !meta.isEmpty { header.append(meta.joined(separator: " · ")) }
        blocks.append(header)

        if !recipe.ingredients.isEmpty {
            blocks.append(["INGREDIENTS"] + recipe.ingredients.map { ingredient in
                var line = ingredient.displayText
                if let note = ingredient.note?.trimmed, !note.isEmpty { line += ", \(note)" }
                return "☐ \(line)"
            })
        }

        let prep = prepLines(recipe, plan: planner.plan(for: recipe))
        if !prep.isEmpty { blocks.append(["PREP FIRST"] + prep) }

        if !recipe.steps.isEmpty {
            // A blank line between steps, so each reads as its own instruction.
            let steps = recipe.steps.enumerated().map { "\($0.offset + 1). \($0.element.trimmed)" }
            blocks.append(["STEPS"] + steps.flatMap { [$0, ""] }.dropLast())
        }
        if !recipe.notes.isEmpty {
            blocks.append(["NOTES"] + recipe.notes.map { "• \($0.trimmed)" })
        }

        var footer: [String] = []
        if let source = recipe.sourceURL { footer.append("Source: \(source.absoluteString)") }
        footer.append("Made with Mise")
        blocks.append(footer)

        return blocks.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    /// "Start early" first (marked, with its time), then chopping and mixing. "Get out" is left
    /// out: the ingredient list already says what to get.
    static func prepLines(_ recipe: Recipe, plan: PrepPlan) -> [String] {
        plan.groups.filter { $0.kind != .getOut }.flatMap { group in
            group.items.map { item in
                var text = item.text(in: recipe)
                if group.kind == .startEarly {
                    // "Start early: marinate …", keeping capitals that start a name ("PB&J").
                    let rest = text.dropFirst()
                    if let first = text.first, rest.first?.isUppercase != true { text = first.lowercased() + rest }
                    text = "Start early: " + text
                    if let minutes = item.minutes { text += " (\(duration(minutes)))" }
                }
                return "☐ \(text)"
            }
        }
    }

    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) hr"
        default: return "\(h) hr \(m) min"
        }
    }
}
