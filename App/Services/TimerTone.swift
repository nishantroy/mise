import AVFoundation
import os

/// The fallback alarm sound when AlarmKit isn't allowed: a repeating double beep, synthesised in
/// memory (no bundled file). Uses the `.playback` audio session category, so it sounds even with
/// the silent switch on, but only while Mise is in the foreground. Stops when dismissed, or after
/// two minutes so a forgotten phone doesn't beep forever.
@MainActor
final class TimerTone {
    private static let log = Logger(subsystem: "Mise", category: "TimerTone")
    private static let sampleRate = 44_100.0

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var limit: Task<Void, Never>?

    var isPlaying: Bool { engine != nil }

    func start() {
        guard engine == nil, let buffer = Self.pattern() else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            self.engine = engine
            self.player = player
            limit = Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            Self.log.error("Timer tone failed: \(String(describing: error), privacy: .public)")
            stop()
        }
    }

    func stop() {
        limit?.cancel()
        limit = nil
        guard engine != nil else { return }
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// One second: two short 1 kHz-ish beeps, then quiet. Looped by the player.
    private static func pattern() -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        let frames = AVAudioFrameCount(sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        let beeps: [(start: Double, length: Double)] = [(0, 0.14), (0.22, 0.14)]
        let ramp = 0.006
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            var value: Float = 0
            if let beep = beeps.first(where: { t >= $0.start && t < $0.start + $0.length }) {
                let local = t - beep.start
                let envelope = min(1, local / ramp, (beep.length - local) / ramp)
                value = Float(sin(2 * .pi * 1_046.5 * t) * 0.7 * envelope)
            }
            samples[i] = value
        }
        return buffer
    }
}
