import AVFoundation
import AppKit

final class AlarmService {
    private var player: AVAudioPlayer?
    private var defaultPlayer: NSSound?
    private var repeatTimer: Timer?
    private var activePath: String?
    private var activeVolume: Double = 0.8

    /// Starts a non-overlapping repeating alarm. It is stopped by the user,
    /// monitor shutdown, or automatic release after the target disappears.
    func startRepeating(path: String?, interval: Double, volume: Double) {
        stop()
        activePath = path
        activeVolume = volume
        playPulse()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.playPulse() }
    }

    private func playPulse() {
        guard !(player?.isPlaying ?? false), !(defaultPlayer?.isPlaying ?? false) else { return }
        if let path = activePath, let audio = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) { player = audio; audio.volume = Float(activeVolume); audio.numberOfLoops = 0; audio.prepareToPlay(); audio.play() }
        else if let sound = NSSound(named: NSSound.Name("Basso")) { defaultPlayer = sound; sound.volume = Float(activeVolume); sound.loops = false; sound.play() }
        else { NSSound.beep() }
    }
    /// Plays one complete preview without changing the alarm's latch state.
    func playOnce(path: String?, volume: Double) {
        guard !(player?.isPlaying ?? false), !(defaultPlayer?.isPlaying ?? false) else { return }
        if let path, let audio = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) { player = audio; audio.volume = Float(volume); audio.numberOfLoops = 0; audio.prepareToPlay(); audio.play() }
        else if let sound = NSSound(named: NSSound.Name("Basso")) { defaultPlayer = sound; sound.volume = Float(volume); sound.loops = false; sound.play() }
        else { NSSound.beep() }
    }
    func stop() { repeatTimer?.invalidate(); repeatTimer = nil; player?.stop(); player = nil; defaultPlayer?.stop(); defaultPlayer = nil }
}
