import AudioToolbox
import AVFoundation

final class SoundManager: @unchecked Sendable {
    private enum BundledSound: String, CaseIterable {
        case keep
        case delete
        case skip
        case undo
        case finish
        case finishAllKept = "finish-kept"

        static let fileExtension = "caf"

        var fallbackSystemSound: SystemSoundID {
            switch self {
            case .keep: 1104
            case .delete: 1105
            case .skip: 1306
            case .undo: 1057
            case .finish, .finishAllKept: 1001
            }
        }
    }

    static let shared = SoundManager()
    private var players: [BundledSound: AVAudioPlayer] = [:]
    private let playbackQueue = DispatchQueue(label: "com.flickpic.sound", qos: .userInteractive)

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
        playbackQueue.async { [players] in
            guard let player = players[sound] else {
                AudioServicesPlaySystemSound(sound.fallbackSystemSound)
                return
            }
            player.currentTime = 0
            player.play()
        }
    }

    static func warmUp() {
        Task.detached(priority: .utility) { _ = shared }
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

    func playAllKept() {
        play(.finishAllKept)
    }

    func playFailure() {
        AudioServicesPlaySystemSound(1519)
    }

    func playSkip() {
        play(.skip)
    }

    func playUndo() {
        play(.undo)
    }
}
