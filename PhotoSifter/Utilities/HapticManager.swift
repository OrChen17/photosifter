import CoreHaptics
import UIKit

@MainActor
final class HapticManager {
    static let shared = HapticManager()

    private var engine: CHHapticEngine?

    private init() {
        prepareEngine()
    }

    func prepareEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            engine?.isAutoShutdownEnabled = true
            try engine?.start()
        } catch {}
    }

    func playKeep() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.9)
    }

    func playDelete() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1.0)
    }

    func playUndo() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
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
            let events = try pattern.map { p in
                try CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: p.intensity),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: p.sharpness),
                    ],
                    relativeTime: p.rel
                )
            }
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
