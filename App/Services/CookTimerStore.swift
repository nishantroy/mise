import AlarmKit
import Foundation
import Observation
import os
import RecipeKit
import SwiftUI
import UIKit
import UserNotifications

/// Cook mode's timers. Several can run at once. Each has a fixed end `Date`, so it stays right
/// after the app is backgrounded or the phone locks; the countdown is computed from it, never
/// decremented.
///
/// Alerts: with AlarmKit allowed, each timer is an AlarmKit countdown, so it rings like the Clock
/// app (through silent mode and Focus) and shows on the Lock Screen and Dynamic Island. Without
/// it, a local notification is scheduled instead and, while Mise is open, a repeating tone plays
/// on finish (`TimerTone`, audible on silent). Permission is asked the first time a timer starts.
@MainActor
@Observable
final class CookTimerStore {
    struct RunningTimer: Identifiable, Equatable {
        let id = UUID()
        /// `CookTimerSpec.id`: which chip started it.
        let specID: String
        let step: Int
        /// What it's for: "Simmer the sauce".
        let name: String
        var endDate: Date
        var finished = false
        /// The AlarmKit alarm currently scheduled for it, if any.
        var alarmID: UUID?

        var title: String { "Step \(step + 1) · \(name)" }
        func remaining(at now: Date) -> TimeInterval { max(0, endDate.timeIntervalSince(now)) }
    }

    /// How finished timers alert outside the app.
    enum AlertRoute { case unknown, alarms, notifications }

    private static let log = Logger(subsystem: "Mise", category: "CookTimers")

    private(set) var timers: [RunningTimer] = []
    /// The most recently finished timer, shown as an in-app banner until dismissed.
    private(set) var banner: RunningTimer?
    private(set) var route: AlertRoute = .unknown
    /// The fallback tone is playing.
    private(set) var ringing = false

    private var waits: [UUID: Task<Void, Never>] = [:]
    /// Alarm IDs seen in an `alarmUpdates` batch. Only these count as "stopped elsewhere" when
    /// they disappear, so an alarm that's still being scheduled isn't mistaken for a cancelled one.
    private var seenAlarms: Set<UUID> = []
    private var routeTask: Task<AlertRoute, Never>?
    private let tone = TimerTone()
    private let recipeTitle: String

    init(recipeTitle: String) {
        self.recipeTitle = recipeTitle
    }

    var hasRunning: Bool { timers.contains { !$0.finished } }

    /// The banner should stay up: something is still sounding.
    var bannerIsSounding: Bool { ringing || banner?.alarmID != nil }

    func running(for spec: CookTimerSpec) -> RunningTimer? {
        timers.first { $0.specID == spec.id && !$0.finished }
    }

    /// Starts the chip's timer for its duration (a range's upper bound).
    func start(_ spec: CookTimerSpec, now: Date = .now) {
        guard running(for: spec) == nil else { return }
        // A finished timer for the same chip makes way for the new one.
        for old in timers where old.specID == spec.id { cancel(old.id) }
        let duration = TimeInterval(max(spec.seconds, Int(CookTimerAdjust.minimumSeconds)))
        let timer = RunningTimer(specID: spec.id, step: spec.step, name: spec.title, endDate: now.addingTimeInterval(duration))
        timers.append(timer)
        arm(timer)
    }

    /// −1 min / +1 min on a running timer. Reschedules its alarm or notification.
    func adjust(_ id: UUID, by delta: TimeInterval, now: Date = .now) {
        guard let index = timers.firstIndex(where: { $0.id == id }), !timers[index].finished else { return }
        let remaining = timers[index].remaining(at: now)
        let target = CookTimerAdjust.adjusted(remaining: remaining, by: delta)
        guard abs(target - remaining) >= 1 else { return }
        disarm(timers[index])
        timers[index].endDate = now.addingTimeInterval(target)
        timers[index].alarmID = nil
        arm(timers[index])
    }

    func cancel(_ id: UUID) {
        guard let timer = timers.first(where: { $0.id == id }) else { return }
        disarm(timer)
        timers.removeAll { $0.id == id }
        if banner?.id == id { dismissBanner() }
    }

    func cancelAll() {
        for timer in timers { cancel(timer.id) }
        dismissBanner()
    }

    /// Hides the banner and silences whatever is sounding (the tone, or the alerting alarm).
    func dismissBanner() {
        stopTone()
        guard let done = banner else { return }
        banner = nil
        if let index = timers.firstIndex(where: { $0.id == done.id }), let alarmID = timers[index].alarmID {
            stopAlarm(alarmID)
            timers[index].alarmID = nil
        }
    }

    /// Finishes timers whose end time has passed (e.g. while the app was in the background).
    func checkExpired(now: Date = .now) {
        for timer in timers where !timer.finished && timer.endDate <= now { finish(timer.id, now: now) }
    }

    /// Follows AlarmKit's alarms while cook mode is open: an alarm that starts alerting finishes
    /// its timer in the app; one that disappears was stopped or cancelled from the Lock Screen,
    /// Dynamic Island or alarm screen, so the app follows.
    func observeAlarms() async {
        for await alarms in AlarmManager.shared.alarmUpdates {
            apply(alarms)
        }
    }

    // MARK: Internals

    private func apply(_ alarms: [Alarm], now: Date = .now) {
        let states = Dictionary(alarms.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        for timer in timers {
            guard let alarmID = timer.alarmID else { continue }
            if let state = states[alarmID] {
                seenAlarms.insert(alarmID)
                if state == .alerting { finish(timer.id, now: now) }
            } else if seenAlarms.contains(alarmID) {
                seenAlarms.remove(alarmID)
                guard let index = timers.firstIndex(where: { $0.id == timer.id }) else { continue }
                timers[index].alarmID = nil
                if timers[index].finished || timer.endDate <= now.addingTimeInterval(1) {
                    // Rang and was stopped outside the app: keep it as "Done", drop the banner.
                    if !timers[index].finished {
                        timers[index].finished = true
                        waits[timer.id]?.cancel()
                        waits[timer.id] = nil
                    }
                    if banner?.id == timer.id { banner = nil }
                } else {
                    // Cancelled before it rang.
                    cancel(timer.id)
                }
            }
        }
    }

    private func arm(_ timer: RunningTimer) {
        waits[timer.id]?.cancel()
        waits[timer.id] = Task { [weak self] in
            let delay = timer.endDate.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.finish(timer.id)
        }
        Task { await scheduleAlert(for: timer.id, endDate: timer.endDate) }
    }

    private func disarm(_ timer: RunningTimer) {
        waits[timer.id]?.cancel()
        waits[timer.id] = nil
        if let alarmID = timer.alarmID {
            seenAlarms.remove(alarmID)
            do {
                try AlarmManager.shared.cancel(id: alarmID)
            } catch {
                Self.log.info("Alarm cancel failed: \(String(describing: error), privacy: .public)")
            }
        }
        let identifier = Self.notificationID(timer.id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func finish(_ id: UUID, now: Date = .now) {
        guard let index = timers.firstIndex(where: { $0.id == id }), !timers[index].finished else { return }
        timers[index].finished = true
        waits[id]?.cancel()
        waits[id] = nil
        banner = timers[index]
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        // The alarm rings by itself. Without one, play the tone, but only for a fresh finish:
        // not for a timer that ran out long ago while Mise was in the background.
        if timers[index].alarmID == nil, now.timeIntervalSince(timers[index].endDate) < 30 {
            tone.start()
            ringing = tone.isPlaying
        }
        // The in-app banner replaces the notification while Mise is open.
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID(id)])
    }

    private func stopTone() {
        tone.stop()
        ringing = false
    }

    private func stopAlarm(_ alarmID: UUID) {
        seenAlarms.remove(alarmID)
        // `stop` silences an alerting alarm; `cancel` removes one that hasn't fired yet.
        do {
            try AlarmManager.shared.stop(id: alarmID)
        } catch {
            try? AlarmManager.shared.cancel(id: alarmID)
        }
    }

    // MARK: Scheduling

    /// AlarmKit when allowed (asked once), otherwise notifications. Re-read each time so a change
    /// in Settings applies to the next timer.
    private func resolveRoute() async -> AlertRoute {
        if let routeTask { return await routeTask.value }
        let task = Task { () -> AlertRoute in
            let manager = AlarmManager.shared
            switch manager.authorizationState {
            case .authorized: return .alarms
            case .denied: return .notifications
            case .notDetermined:
                do {
                    return try await manager.requestAuthorization() == .authorized ? .alarms : .notifications
                } catch {
                    Self.log.error("AlarmKit authorization failed: \(String(describing: error), privacy: .public)")
                    return .notifications
                }
            @unknown default: return .notifications
            }
        }
        routeTask = task
        let value = await task.value
        routeTask = nil
        route = value
        return value
    }

    /// Schedules the outside-the-app alert for a timer's current end date. Drops the result if the
    /// timer changed meanwhile (adjusted, cancelled, finished).
    private func scheduleAlert(for id: UUID, endDate: Date) async {
        let route = await resolveRoute()
        func current() -> RunningTimer? {
            timers.first { $0.id == id && $0.endDate == endDate && !$0.finished }
        }
        guard let timer = current() else { return }
        let remaining = endDate.timeIntervalSinceNow
        guard remaining >= 1 else { return }
        if route == .alarms {
            let alarmID = UUID()
            do {
                try await Self.scheduleAlarm(id: alarmID, duration: remaining, attributes: alarmAttributes(for: timer))
                if current() != nil, let index = timers.firstIndex(where: { $0.id == id }) {
                    timers[index].alarmID = alarmID
                } else {
                    try? AlarmManager.shared.cancel(id: alarmID)
                }
                return
            } catch {
                // E.g. the system's alarm limit: fall back to a notification for this one.
                Self.log.error("Alarm not scheduled: \(String(describing: error), privacy: .public)")
            }
        }
        await scheduleNotification(for: timer)
    }

    /// The configuration isn't Sendable, so it's built where it's used, off the main actor.
    private nonisolated static func scheduleAlarm(id: UUID, duration: TimeInterval,
                                                  attributes: AlarmAttributes<CookTimerMetadata>) async throws {
        let configuration = AlarmManager.AlarmConfiguration<CookTimerMetadata>.timer(duration: duration, attributes: attributes)
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
    }

    /// Countdown title "Simmer the sauce", alert "Simmer the sauce: done", "Step 3 · Chow mein" below.
    private func alarmAttributes(for timer: RunningTimer) -> AlarmAttributes<CookTimerMetadata> {
        let name = timer.name
        let alertTitle: LocalizedStringResource = "\(name): done"
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: alertTitle)
        } else {
            alert = AlarmPresentation.Alert(title: alertTitle,
                                            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill"))
        }
        let presentation = AlarmPresentation(alert: alert, countdown: AlarmPresentation.Countdown(title: "\(name)"))
        let metadata = CookTimerMetadata(recipeTitle: recipeTitle, step: timer.step + 1, timerTitle: name)
        return AlarmAttributes(presentation: presentation, metadata: metadata, tintColor: CookTimerColors.accent)
    }

    // MARK: Notifications (fallback)

    private static func notificationID(_ id: UUID) -> String { "mise.timer.\(id.uuidString)" }

    private func scheduleNotification(for timer: RunningTimer) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Self.log.error("Notification permission request failed: \(String(describing: error), privacy: .public)")
            }
        }
        // Adjusted or cancelled while permission was being asked.
        guard timers.contains(where: { $0.id == timer.id && $0.endDate == timer.endDate && !$0.finished }) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Timer done"
        content.body = "\(recipeTitle): \(timer.title)"
        content.sound = .default
        let interval = max(1, timer.endDate.timeIntervalSinceNow)
        let request = UNNotificationRequest(identifier: Self.notificationID(timer.id), content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        do {
            try await center.add(request)
        } catch {
            // Denied or unavailable: the in-app banner, tone and haptic still work.
            Self.log.info("Timer notification not scheduled: \(String(describing: error), privacy: .public)")
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
