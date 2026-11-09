import CoreHaptics
import UIKit

@MainActor
final class HapticManager {
    static let shared = HapticManager()

    private var engine: CHHapticEngine?
    private var keepPlayer: CHHapticPatternPlayer?
    private var deletePlayer: CHHapticPatternPlayer?
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let medium = UIImpactFeedbackGenerator(style: .medium)

    private init() {
        prepareEngine()
        [rigid, heavy, medium].forEach { $0.prepare() }
    }

    func prepareEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak self] in
                Task { @MainActor in self?.rebuildPlayers() }
            }
            try engine.start()
            self.engine = engine
            rebuildPlayers()
        } catch {}
    }

    private func rebuildPlayers() {
        guard let engine else { return }
        try? engine.start()
        keepPlayer = try? engine.makePlayer(with: Self.keepPattern())
        deletePlayer = try? engine.makePlayer(with: Self.deletePattern())
    }

    func playKeep() {
        if play(keepPlayer) { return }
        rigid.impactOccurred(intensity: 0.9)
        rigid.prepare()
    }

    func playDelete() {
        if play(deletePlayer) { return }
        heavy.impactOccurred(intensity: 1.0)
        heavy.prepare()
    }

    private func play(_ player: CHHapticPatternPlayer?) -> Bool {
        guard let player else { return false }
        do {
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            rebuildPlayers()
            return false
        }
    }

    private static func keepPattern() throws -> CHHapticPattern {
        try CHHapticPattern(events: [
            transient(at: 0, intensity: 0.9, sharpness: 0.9),
            transient(at: KeepTap.gap, intensity: 0.65, sharpness: 1.0),
        ], parameters: [])
    }

    private static func deletePattern() throws -> CHHapticPattern {
        let thud = transient(at: 0, intensity: 1.0, sharpness: 0.15)
        let rumble = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.05),
            ],
            relativeTime: 0.01,
            duration: DeleteThud.tail
        )
        let fade = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 1),
                .init(relativeTime: DeleteThud.tail, value: 0),
            ],
            relativeTime: 0.01
        )
        return try CHHapticPattern(events: [thud, rumble], parameterCurves: [fade])
    }

    private static func transient(at time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: time
        )
    }

    func playUndo() {
        medium.impactOccurred(intensity: 1.0)
        medium.prepare()
    }

    func playBatchComplete() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics,
              let engine else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }

        let pattern: [(rel: Double, intensity: Float, sharpness: Float)] = [
            (0.0, 0.6, 0.5),
            (0.1, 0.8, 0.7),
            (0.2, 1.0, 1.0),
            (0.35, 0.5, 0.3),
        ]

        do {
            let events = pattern.map { Self.transient(at: $0.rel, intensity: $0.intensity, sharpness: $0.sharpness) }
            let hapticPattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: hapticPattern)
            try engine.start()
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {}
    }

    func playDragTick() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // Light tick for counters and countdown — same feel as drag threshold but contextually distinct
    func playTick() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // Light tap for navigation and CTA buttons
    func playNavigate() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.8)
    }
}

private enum KeepTap {
    static let gap: TimeInterval = 0.07
}

private enum DeleteThud {
    static let tail: TimeInterval = 0.22
}
