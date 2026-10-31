import Foundation

/// A cooking session that survives closing cook mode or the app being killed: the page, prep
/// ticks, swaps and timers. Stored per recipe by the app (outside SwiftData); expires after
/// `lifetime` without activity.
public struct CookSession: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    /// Sessions untouched for longer than this aren't offered for resuming.
    public static let lifetime: TimeInterval = 12 * 3600

    public var version: Int
    public var recipeID: UUID
    /// `PrepPlanner.fingerprint` of the saved recipe when cooking started; an edited recipe
    /// doesn't resume (ingredient IDs and steps may no longer line up).
    public var fingerprint: String
    /// The servings cook mode was showing (amounts in swaps and the plan follow them).
    public var servings: Int?
    /// 0 = prep list, n = step n.
    public var page: Int
    public var checkedPrep: [String]
    /// The prep list as shown (rules or model), so ticks keep pointing at the same items.
    public var plan: PrepPlan?
    public var swaps: [CookSwap]
    public var timers: [CookSessionTimer]
    public var startedAt: Date
    public var updatedAt: Date

    public init(recipeID: UUID, fingerprint: String, servings: Int?, page: Int = 0, checkedPrep: [String] = [],
                plan: PrepPlan? = nil, swaps: [CookSwap] = [], timers: [CookSessionTimer] = [], startedAt: Date = .now,
                updatedAt: Date = .now) {
        self.version = Self.currentVersion
        self.recipeID = recipeID
        self.fingerprint = fingerprint
        self.servings = servings
        self.page = page
        self.checkedPrep = checkedPrep
        self.plan = plan
        self.swaps = swaps
        self.timers = timers
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    public func isExpired(at now: Date) -> Bool { now.timeIntervalSince(updatedAt) > Self.lifetime }

    /// Still the same recipe (ingredients and steps unchanged since cooking started).
    public func fits(_ recipe: Recipe) -> Bool { fingerprint == PrepPlanner.fingerprint(recipe) }

    /// Worth offering "Resume cooking": past the prep list, or something ticked, swapped or timed.
    public var hasProgress: Bool { page > 0 || !checkedPrep.isEmpty || !swaps.isEmpty || !timers.isEmpty }

    /// Whether the app should offer this session for `recipe` at `now`.
    public func isResumable(for recipe: Recipe, at now: Date) -> Bool {
        version == Self.currentVersion && !isExpired(at: now) && fits(recipe) && hasProgress
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data) -> CookSession? {
        guard let session = try? JSONDecoder().decode(CookSession.self, from: data), session.version == currentVersion else { return nil }
        return session
    }
}

/// A cook-mode timer as stored in a session.
public struct CookSessionTimer: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// `CookTimerSpec.id` of the chip that started it.
    public var specID: String
    public var step: Int
    public var name: String
    public var endDate: Date
    public var finished: Bool
    /// The AlarmKit alarm scheduled for it, if any (nil: a notification was used instead).
    public var alarmID: UUID?

    public init(id: UUID, specID: String, step: Int, name: String, endDate: Date, finished: Bool, alarmID: UUID?) {
        self.id = id
        self.specID = specID
        self.step = step
        self.name = name
        self.endDate = endDate
        self.finished = finished
        self.alarmID = alarmID
    }
}

/// An AlarmKit alarm's state, reduced to what reconciling needs.
public enum CookAlarmState: Sendable, Hashable {
    /// Scheduled, counting down or paused.
    case pending
    /// Ringing now.
    case alerting
}

/// Matching stored timers with the alarms that still exist when a session resumes.
public enum CookTimerReconciler {
    /// - A running timer whose end has passed is done.
    /// - A running timer whose alarm no longer exists was stopped or cancelled from the Lock Screen,
    ///   Dynamic Island or alarm screen: dropped before its end, done after it.
    /// - A done timer keeps its alarm only while it's ringing (so the banner can stop it).
    /// - `alarms` nil means the alarm list couldn't be read: alarms are trusted to still exist.
    /// - Timers without an alarm (notification fallback) follow their end date only.
    public static func reconcile(_ timers: [CookSessionTimer], alarms: [UUID: CookAlarmState]?, now: Date) -> [CookSessionTimer] {
        timers.compactMap { timer in
            var t = timer
            let state = t.alarmID.flatMap { alarms?[$0] }
            let alarmGone = t.alarmID != nil && alarms != nil && state == nil
            if !t.finished && t.endDate <= now { t.finished = true }
            if t.finished {
                if alarmGone || (alarms != nil && state != .alerting) { t.alarmID = nil }
                return t
            }
            return alarmGone ? nil : t
        }
    }
}

extension PrepPlan {
    /// The plan with swapped ingredients' IDs replaced by their replacements' (a skipped
    /// ingredient simply goes missing from the recipe, so its items drop it when rendered).
    public func substituting(_ map: [UUID: [UUID]]) -> PrepPlan {
        guard !map.isEmpty else { return self }
        var copy = self
        for g in copy.groups.indices {
            for i in copy.groups[g].items.indices {
                var item = copy.groups[g].items[i]
                guard item.ingredientIDs.contains(where: { map[$0] != nil }) else { continue }
                item.ingredientIDs = item.ingredientIDs.flatMap { map[$0] ?? [$0] }
                for old in map.keys { item.details[old] = nil }
                copy.groups[g].items[i] = item
            }
        }
        return copy
    }

    /// Items that cover `id`.
    public func itemIDs(covering id: UUID) -> [String] {
        items.filter { $0.ingredientIDs.contains(id) }.map(\.id)
    }

    /// Without items whose ingredients are all gone from `recipe` (skipped) and that have
    /// nothing else to say.
    public func visible(in recipe: Recipe) -> PrepPlan {
        let groups = groups.map { group in
            PrepGroup(kind: group.kind, items: group.items.filter { item in
                item.ingredientIDs.isEmpty || item.ingredientIDs.contains { recipe.ingredient(id: $0) != nil } || item.subject != nil
            })
        }
        return PrepPlan(groups: groups, source: source)
    }
}
