import Foundation

/// Mise's estimate of how long a recipe really takes. An estimate, not a verification: the
/// source's stated time (`Recipe.totalMinutes`) is kept and shown alongside it.
public struct TimeEstimate: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Hashable, Sendable {
        case rules, model
    }

    /// Active + passive, rounded to the nearest 5 minutes (minimum 5).
    public var totalMinutes: Int
    /// Prep plus hands-on cooking (simmering and baking count as cooking).
    public var activeMinutes: Int
    /// Waiting: marinating, resting, chilling, rising, soaking, setting, cooling, overnight.
    public var passiveMinutes: Int
    /// One line explaining the number.
    public var reason: String
    public var source: Source
    /// What most of the passive time is ("marinating"), or "waiting" when it's mixed.
    public var passiveLabel: String?
    /// A step says "overnight" (counted as 8 hours of passive time).
    public var isOvernight: Bool
    /// `TimeEstimate.basis(for:)` of the recipe this was computed from. Nil (estimates saved
    /// before it existed) or different from the recipe's current basis means the estimate is
    /// stale: the steps or ingredients changed since, or the rules did.
    public var basis: String?

    public init(totalMinutes: Int, activeMinutes: Int, passiveMinutes: Int, reason: String, source: Source,
                passiveLabel: String? = nil, isOvernight: Bool = false, basis: String? = nil) {
        self.totalMinutes = totalMinutes
        self.activeMinutes = activeMinutes
        self.passiveMinutes = passiveMinutes
        self.reason = reason
        self.source = source
        self.passiveLabel = passiveLabel
        self.isOvernight = isOvernight
        self.basis = basis
    }

    enum CodingKeys: String, CodingKey {
        case totalMinutes, activeMinutes, passiveMinutes, reason, source, passiveLabel, isOvernight, basis
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalMinutes = try c.decode(Int.self, forKey: .totalMinutes)
        activeMinutes = try c.decodeIfPresent(Int.self, forKey: .activeMinutes) ?? totalMinutes
        passiveMinutes = try c.decodeIfPresent(Int.self, forKey: .passiveMinutes) ?? 0
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .rules
        passiveLabel = try c.decodeIfPresent(String.self, forKey: .passiveLabel)
        isOvernight = try c.decodeIfPresent(Bool.self, forKey: .isOvernight) ?? false
        basis = (try? c.decodeIfPresent(String.self, forKey: .basis)) ?? nil
    }

    /// What an estimate depends on: the steps, the ingredient names and the rules' version
    /// (`TimeEstimator.rulesVersion`). Title, servings, quantities, notes and cuisine don't
    /// change it. A stable 64-bit FNV-1a hash in hex (Swift's `Hasher` is seeded per launch).
    public static func basis(for recipe: Recipe) -> String {
        let text = "v\(TimeEstimator.rulesVersion)\n"
            + recipe.ingredients.map { $0.name.lowercased() }.joined(separator: "\n")
            + "\n--\n" + recipe.steps.joined(separator: "\n")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Computed from the recipe as it is now (same steps, ingredients and rules).
    public func fits(_ recipe: Recipe) -> Bool {
        basis == Self.basis(for: recipe)
    }

    /// The same estimate, marked as computed from `recipe`.
    public func stamped(for recipe: Recipe) -> TimeEstimate {
        var copy = self
        copy.basis = Self.basis(for: recipe)
        return copy
    }
}

extension Recipe {
    /// The stored estimate when it fits the recipe as it is now; otherwise (stale) the rules'
    /// estimate for the current steps. Nil when nothing is stored.
    public func currentTimeEstimate(catalog: IngredientCatalog = .shared) -> TimeEstimate? {
        guard let estimate = timeEstimate else { return nil }
        return estimate.fits(self) ? estimate : TimeEstimator(catalog: catalog).estimate(self)
    }

    /// True when an estimate is stored but was computed from different steps/ingredients
    /// (or older rules).
    public var hasStaleTimeEstimate: Bool {
        guard let estimate = timeEstimate else { return false }
        return !estimate.fits(self)
    }

    /// The recipe with a stale estimate replaced by the rules' estimate for its current steps;
    /// unchanged when the estimate fits or there is none. Applied wherever a recipe is saved, so
    /// edits (Paste my version, I made this, adjust, reset to original, cook-mode swaps) never
    /// keep an estimate computed from other steps.
    public func refreshingStaleTimeEstimate(catalog: IngredientCatalog = .shared) -> Recipe {
        guard hasStaleTimeEstimate else { return self }
        var copy = self
        copy.timeEstimate = TimeEstimator(catalog: catalog).estimate(self)
        return copy
    }

    /// True when the estimate exceeds the stated time by a meaningful margin
    /// (see `TimeEstimator.isMismatch`). False when either is missing.
    public var timeMismatch: Bool {
        guard let estimate = timeEstimate else { return false }
        return TimeEstimator.isMismatch(estimate: estimate.totalMinutes, stated: totalMinutes)
    }

    /// The time to show in compact metadata: the stated time, or the estimate when the page
    /// gave none (flagged so it can be shown as "~45 min").
    public var displayTime: (minutes: Int, isEstimate: Bool)? {
        if let stated = totalMinutes, stated > 0 { return (stated, false) }
        if let estimate = timeEstimate { return (estimate.totalMinutes, true) }
        return nil
    }

    /// The longer of the stated time and the estimate: what a weeknight check should use.
    public var realisticMinutes: Int? {
        let values = [totalMinutes, timeEstimate?.totalMinutes].compactMap { $0 }.filter { $0 > 0 }
        return values.max()
    }

    /// The realistic time is longer than the user's weeknight limit (if they set one).
    public func exceedsWeeknightTime(_ prefs: UserPreferences) -> Bool {
        guard let limit = prefs.weeknightMinutes, limit > 0, let minutes = realisticMinutes else { return false }
        return minutes > limit
    }

    /// The cuisine came from the page or the user, so guessing must leave it alone.
    public var hasGivenCuisine: Bool {
        guard let cuisine, !cuisine.trimmed.isEmpty else { return false }
        return !cuisineIsGuess
    }

    /// Fills the guessed fields. A page or user cuisine is never replaced; an earlier guess is
    /// replaced by a new one but kept when the new guess is nil. The estimate is replaced when given.
    public func withInsights(cuisineGuess: String?, estimate: TimeEstimate?) -> Recipe {
        var copy = self
        if !hasGivenCuisine, let guess = cuisineGuess, !guess.trimmed.isEmpty {
            copy.cuisine = guess
            copy.cuisineIsGuess = true
        }
        if let estimate { copy.timeEstimate = estimate }
        return copy
    }
}
