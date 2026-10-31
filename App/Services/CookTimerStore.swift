import AudioToolbox
import Foundation
import Observation
import os
import RecipeKit
import UIKit
import UserNotifications

/// Cook mode's timers. Several can run at once. Each has a fixed end `Date`, so it stays right
/// after the app is backgrounded or the phone locks; the countdown is computed from it, never
/// decremented. A local notification is scheduled for each so it fires in the background too.
/// Permission is asked the first time a timer starts; without it, timers still work in the app.
@MainActor
@Observable
final class CookTimerStore {
    struct RunningTimer: Identifiable, Equatable {
        let id = UUID()
        /// `CookTimerSpec.id`: which chip started it.
        let specID: String
        let step: Int
        let label: String
        let endDate: Date
        var finished = false

        var title: String { "Step \(step + 1) · \(label)" }
        func remaining(at now: Date) -> TimeInterval { max(0, endDate.timeIntervalSince(now)) }
    }

    private static let log = Logger(subsystem: "Mise", category: "CookTimers")

    private(set) var timers: [RunningTimer] = []
    /// The most recently finished timer, shown as an in-app banner until dismissed.
    var banner: RunningTimer?
    private var waits: [UUID: Task<Void, Never>] = [:]
    private let recipeTitle: String

    init(recipeTitle: String) {
        self.recipeTitle = recipeTitle
    }

    var hasRunning: Bool { timers.contains { !$0.finished } }

    func running(for spec: CookTimerSpec) -> RunningTimer? {
        timers.first { $0.specID == spec.id && !$0.finished }
    }

    func start(_ spec: CookTimerSpec, now: Date = .now) {
        guard running(for: spec) == nil else { return }
        // A finished timer for the same chip makes way for the new one.
        timers.removeAll { $0.specID == spec.id }
        let timer = RunningTimer(specID: spec.id, step: spec.step, label: spec.label,
                                 endDate: now.addingTimeInterval(TimeInterval(spec.seconds)))
        timers.append(timer)
        scheduleNotification(for: timer)
        waits[timer.id] = Task { [weak self] in
            let delay = timer.endDate.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.finish(timer.id)
        }
    }

    func cancel(_ id: UUID) {
        waits[id]?.cancel()
        waits[id] = nil
        timers.removeAll { $0.id == id }
        if banner?.id == id { banner = nil }
        let identifier = Self.notificationID(id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func cancelAll() {
        for timer in timers { cancel(timer.id) }
        banner = nil
    }

    /// Finishes timers whose end time has passed (e.g. while the app was in the background).
    func checkExpired(now: Date = .now) {
        for timer in timers where !timer.finished && timer.endDate <= now { finish(timer.id) }
    }

    private func finish(_ id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }), !timers[index].finished else { return }
        timers[index].finished = true
        waits[id] = nil
        banner = timers[index]
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AudioServicesPlayAlertSound(SystemSoundID(1005))
        // The in-app banner replaces the notification while Mise is open.
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID(id)])
    }

    // MARK: Notifications

    private static func notificationID(_ id: UUID) -> String { "mise.timer.\(id.uuidString)" }

    private func scheduleNotification(for timer: RunningTimer) {
        let title = recipeTitle
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                do {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                } catch {
                    Self.log.error("Notification permission request failed: \(String(describing: error), privacy: .public)")
                }
            }
            let content = UNMutableNotificationContent()
            content.title = "Timer done"
            content.body = "\(title): \(timer.title)"
            content.sound = .default
            let interval = max(1, timer.endDate.timeIntervalSinceNow)
            let request = UNNotificationRequest(identifier: Self.notificationID(timer.id), content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
            do {
                try await center.add(request)
            } catch {
                // Denied or unavailable: the in-app banner, sound and haptic still work.
                Self.log.info("Timer notification not scheduled: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// Prep plans cached per recipe revision (the plan's fingerprint changes with any edit to the
/// ingredients or steps) for the life of the app process.
@MainActor
enum PrepPlanCache {
    private static var plans: [String: PrepPlan] = [:]

    static func key(_ recipe: Recipe, usesModel: Bool) -> String {
        (usesModel ? "model|" : "rules|") + PrepPlanner.fingerprint(recipe)
    }

    static func plan(for recipe: Recipe, usesModel: Bool) -> PrepPlan? { plans[key(recipe, usesModel: usesModel)] }

    static func store(_ plan: PrepPlan, for recipe: Recipe, usesModel: Bool) {
        plans[key(recipe, usesModel: usesModel)] = plan
    }
}
