import AudioToolbox
import AVFoundation

final class SoundManager: @unchecked Sendable {
    static let shared = SoundManager()
    private var players: [String: AVAudioPlayer] = [:]

    private init() {
        preload("keep",   resource: "keep",   ext: "caf")
        preload("delete", resource: "delete", ext: "caf")
    }

    private func preload(_ key: String, resource: String, ext: String) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext) else { return }
        players[key] = try? AVAudioPlayer(contentsOf: url)
        players[key]?.prepareToPlay()
    }

    func playKeep() {
        if let p = players["keep"] { p.play(); return }
        AudioServicesPlaySystemSound(1104)
    }

    func playDelete() {
        if let p = players["delete"] { p.play(); return }
        AudioServicesPlaySystemSound(1105)
    }

    func playSuccess() {
        AudioServicesPlaySystemSound(1001)  // mail-sent swoosh — satisfying, bigger than a tick
    }

    func playFailure() {
        AudioServicesPlaySystemSound(1519) 
    }
}
