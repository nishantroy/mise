import AlarmKit
import Foundation
import os
import RecipeKit
import UserNotifications

/// Cook sessions, one per recipe, kept in `UserDefaults` as JSON (small, recomputable, and
/// outside SwiftData so no schema change). Expired or unreadable sessions are dropped on load.
@MainActor
enum CookSessionStore {
    private static let key = "cookSessions"
    private static let log = Logger(subsystem: "Mise", category: "CookSession")

    private static var all: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The session for a recipe, if it can still be resumed against `recipe` (not expired, same
    /// ingredients and steps, something to resume). Stale ones are removed.
    static func resumable(for recipeID: UUID, recipe: Recipe, now: Date = .now) -> CookSession? {
        guard let data = all[recipeID.uuidString] else { return nil }
        guard let session = CookSession.decode(data), session.isResumable(for: recipe, at: now) else {
            clear(recipeID)
            return nil
        }
        return session
    }

    static func save(_ session: CookSession) {
        guard let data = session.encoded() else { return }
        all[session.recipeID.uuidString] = data
    }

    static func clear(_ recipeID: UUID) {
        var sessions = all
        guard sessions.removeValue(forKey: recipeID.uuidString) != nil else { return }
        all = sessions
    }

    /// UI tests (`-resetData`).
    static func clearAll() { UserDefaults.standard.removeObject(forKey: key) }

    /// "Start over" on a resumable session: its running alarms and notifications are cancelled too.
    static func discard(_ session: CookSession) {
        for timer in session.timers {
            if let alarmID = timer.alarmID {
                do { try AlarmManager.shared.cancel(id: alarmID) } catch {
                    try? AlarmManager.shared.stop(id: alarmID)
                }
            }
            let identifier = CookTimerStore.notificationID(timer.id)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        }
        clear(session.recipeID)
    }

    /// AlarmKit's current alarms, for reconciling a resumed session; nil if they can't be read.
    static func alarmStates() -> [UUID: CookAlarmState]? {
        do {
            let alarms = try AlarmManager.shared.alarms
            return Dictionary(alarms.map { ($0.id, $0.state == .alerting ? CookAlarmState.alerting : .pending) },
                              uniquingKeysWith: { a, _ in a })
        } catch {
            log.info("Alarm list unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
