import AVFoundation
import Foundation

/// Plays soundboard sounds. One prepared player per sound is kept ready so a hit only has to call
/// `play()`; overlapping hits of the same sound get a temporary extra player.
public final class SoundPlayer: NSObject, SoundPlaying, AVAudioPlayerDelegate {
    private let lock = NSLock()
    private var ready: [URL: AVAudioPlayer] = [:]
    private var transient: [AVAudioPlayer] = []
    public var onPlay: ((TimeInterval) -> Void)?
    public var volume: Float = 1

    public override init() {
        super.init()
    }

    /// Decodes and prepares every sound up front.
    public func preload(_ urls: [URL]) {
        for url in urls {
            guard let player = makePlayer(url) else { continue }
            lock.lock()
            ready[url] = player
            lock.unlock()
        }
    }

    /// Starts the output device with a silent play so the first real hit doesn't pay for it.
    public func warmUp() {
        lock.lock()
        let player = ready.values.first
        lock.unlock()
        guard let player else { return }
        player.volume = 0
        player.play()
        player.stop()
        player.currentTime = 0
        player.volume = volume
        player.prepareToPlay()
    }

    public func play(url: URL) {
        lock.lock()
        var player = ready[url]
        if let cached = player, cached.isPlaying {
            player = nil
        }
        lock.unlock()

        if player == nil {
            guard let fresh = makePlayer(url) else { return }
            lock.lock()
            if ready[url] == nil {
                ready[url] = fresh
            } else {
                transient.append(fresh)
            }
            lock.unlock()
            player = fresh
        }

        guard let player else { return }
        player.currentTime = 0
        player.volume = volume
        onPlay?(player.duration)
        player.play()
    }

    private func makePlayer(_ url: URL) -> AVAudioPlayer? {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            return player
        } catch {
            fputs("Sound playback error for \(url.path): \(error)\n", stderr)
            return nil
        }
    }

    private func finished(_ player: AVAudioPlayer) {
        lock.lock()
        let wasTransient = transient.contains { $0 === player }
        transient.removeAll { $0 === player }
        lock.unlock()
        if !wasTransient {
            player.prepareToPlay()
        }
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finished(player)
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finished(player)
    }
}
