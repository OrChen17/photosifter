import AudioToolbox
import AVFoundation

final class SoundManager: @unchecked Sendable {
    private enum BundledSound: String, CaseIterable {
        case keep
        case delete
        case finish

        static let fileExtension = "caf"

        var fallbackSystemSound: SystemSoundID {
            switch self {
            case .keep: 1104
            case .delete: 1105
            case .finish: 1001
            }
        }
    }

    static let shared = SoundManager()
    private var players: [BundledSound: AVAudioPlayer] = [:]

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        BundledSound.allCases.forEach(preload)
    }

    private func preload(_ sound: BundledSound) {
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: BundledSound.fileExtension),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.prepareToPlay()
        players[sound] = player
    }

    private func play(_ sound: BundledSound) {
        guard let player = players[sound] else {
            AudioServicesPlaySystemSound(sound.fallbackSystemSound)
            return
        }
        player.currentTime = 0
        player.play()
    }

    func playKeep() {
        play(.keep)
    }

    func playDelete() {
        play(.delete)
    }

    func playSuccess() {
        play(.finish)
    }

    func playFailure() {
        AudioServicesPlaySystemSound(1519)
    }

    /// Light "tick" for skip — a forward step.
    func playSkip() {
        AudioServicesPlaySystemSound(1306)
    }

    /// Short rewind-y tone for revert/undo.
    func playUndo() {
        AudioServicesPlaySystemSound(1057)
    }
}
