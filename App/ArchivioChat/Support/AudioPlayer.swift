import SwiftUI
import AVFoundation
import Observation

/// Riproduce un vocale alla volta.
@MainActor
@Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var currentID: Int64?
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var durations: [URL: TimeInterval] = [:]

    func duration(of url: URL) async -> TimeInterval? {
        if let d = durations[url] { return d }
        let d = await Task.detached(priority: .utility) { (try? AVAudioPlayer(contentsOf: url))?.duration }.value
        if let d { durations[url] = d }
        return d
    }

    func toggle(id: Int64, url: URL) {
        if currentID == id, let player {
            if player.isPlaying { player.pause(); isPlaying = false } else { player.play(); isPlaying = true }
            return
        }
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.play()
            player = p
            currentID = id
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            stop()
        }
    }

    func seek(id: Int64, to fraction: Double) {
        guard currentID == id, let player else { return }
        player.currentTime = player.duration * fraction
        progress = fraction
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        currentID = nil
        isPlaying = false
        progress = 0
    }

    private func tick() {
        guard let player, player.duration > 0 else { return }
        progress = player.currentTime / player.duration
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
