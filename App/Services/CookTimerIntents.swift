import AlarmKit
import AppIntents
import Foundation

/// "Stop" on a cook timer's Live Activity (Lock Screen, expanded Dynamic Island). Compiled into
/// the app and the MiseWidgets extension: the widget's button names it, and as a
/// `LiveActivityIntent` it runs in the app's process. Cook mode follows through
/// `AlarmManager.alarmUpdates` (an alarm that disappears before its end time is a cancelled timer).
struct StopCookTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Cook Timer"
    static let description = IntentDescription("Stops a running Mise cook timer.")
    /// Only meaningful from the Live Activity, so it stays out of Shortcuts and Spotlight.
    static let isDiscoverable = false

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}

    init(alarmID: UUID) {
        self.alarmID = alarmID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else { return .result() }
        let manager = AlarmManager.shared
        // A countdown is cancelled; an alarm that's already ringing is stopped.
        let alerting = (try? manager.alarms)?.first { $0.id == id }?.state == .alerting
        do {
            if alerting { try manager.stop(id: id) } else { try manager.cancel(id: id) }
        } catch {
            try? manager.stop(id: id)
        }
        return .result()
    }
}
