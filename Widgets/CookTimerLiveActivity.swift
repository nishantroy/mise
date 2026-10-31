import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct MiseWidgets: WidgetBundle {
    var body: some Widget {
        CookTimerLiveActivity()
    }
}

/// The Lock Screen and Dynamic Island face of a cook-mode AlarmKit countdown. AlarmKit starts and
/// ends the Live Activity itself; this draws it, with a Stop button (`StopCookTimerIntent`) on the
/// Lock Screen and in the expanded Dynamic Island. The compact views are countdown-only.
struct CookTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<CookTimerMetadata>.self) { context in
            LockScreenTimerView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.mise.background)
                .activitySystemActionForegroundColor(Color.mise.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(title(context.attributes)).lineLimit(1)
                    } icon: {
                        Image(systemName: "timer")
                    }
                    .font(.headline)
                    .foregroundStyle(CookTimerColors.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerCountdown(state: context.state)
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: 110, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        if let subtitle = context.attributes.metadata?.subtitle {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        StopTimerButton(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(CookTimerColors.accent)
            } compactTrailing: {
                TimerCountdown(state: context.state)
                    .frame(maxWidth: 56)
                    .foregroundStyle(CookTimerColors.accent)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(CookTimerColors.accent)
            }
            .keylineTint(CookTimerColors.accent)
        }
    }

    private func title(_ attributes: AlarmAttributes<CookTimerMetadata>) -> String {
        attributes.metadata?.timerTitle ?? "Timer"
    }
}

private struct LockScreenTimerView: View {
    let attributes: AlarmAttributes<CookTimerMetadata>
    let state: AlarmPresentationState

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            Image(systemName: "timer")
                .font(.title2)
                .foregroundStyle(Color.mise.onAccent)
                .frame(width: Theme.Size.minTap, height: Theme.Size.minTap)
                .background(Color.mise.accent, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(attributes.metadata?.timerTitle ?? "Timer")
                    .font(Theme.Fonts.sectionTitle)
                    .fontDesign(.serif)
                    .foregroundStyle(Color.mise.ink)
                    .lineLimit(1)
                if let subtitle = attributes.metadata?.subtitle {
                    Text(subtitle)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Color.mise.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                TimerCountdown(state: state)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Color.mise.accent)
                    .lineLimit(1)
                    .frame(maxWidth: 130, alignment: .trailing)
                StopTimerButton(state: state)
            }
        }
        .padding(Theme.Spacing.m)
    }
}

/// Cancels the countdown (or silences it if it's ringing) without opening Mise.
private struct StopTimerButton: View {
    let state: AlarmPresentationState

    var body: some View {
        if case .alert = state.mode {
            EmptyView()
        } else {
            Button(intent: StopCookTimerIntent(alarmID: state.alarmID)) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(CookTimerColors.accent)
            .accessibilityLabel("Stop timer")
        }
    }
}

/// "4:05" counting down, "Paused 2:10", or "Done" once it rings.
private struct TimerCountdown: View {
    let state: AlarmPresentationState

    var body: some View {
        switch state.mode {
        case .countdown(let countdown):
            Text(timerInterval: min(countdown.startDate, countdown.fireDate)...countdown.fireDate, countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        case .paused(let paused):
            let left = max(0, paused.totalCountdownDuration - paused.previouslyElapsedDuration)
            Text(Duration.seconds(left).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit()
        case .alert:
            Text("Done")
        @unknown default:
            Text("Timer")
        }
    }
}
