import AVFoundation
import AppKit

enum WarningVoice {
    case intel, local
    var message: String { self == .intel ? "周边有预警情报，请注意安全。" : "警报！本地进人了！立即注意！" }
    var rate: Float { self == .intel ? 175 : 240 }
    var interval: Double { self == .intel ? 12 : 4 }
}

final class AlarmService {
    private var speech: NSSpeechSynthesizer?
    private var voiceMessage = ""
    func startVoice(_ kind: WarningVoice, volume: Double, repeating: Bool = true) {
        stop()
        let synthesizer = NSSpeechSynthesizer()
        if let voice = NSSpeechSynthesizer.availableVoices.first(where: { $0.rawValue.contains("Tingting") }) ?? NSSpeechSynthesizer.availableVoices.first(where: {
            (NSSpeechSynthesizer.attributes(forVoice: $0)[.localeIdentifier] as? String)?.hasPrefix("zh") == true
        }) { synthesizer.setVoice(voice) }
        synthesizer.rate = kind.rate
        synthesizer.volume = Float(max(0,min(1,volume)))
        speech = synthesizer; voiceMessage = kind.message
        speakVoice()
        if repeating {
            repeatTimer = Timer.scheduledTimer(withTimeInterval: kind.interval, repeats: true) { [weak self] _ in self?.speakVoice() }
        }
    }
    private func speakVoice() {
        guard let speech, !speech.isSpeaking else { return }
        speech.startSpeaking(voiceMessage)
    }
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
    func stop() { speech?.stopSpeaking(); speech = nil; voiceMessage = ""; repeatTimer?.invalidate(); repeatTimer = nil; player?.stop(); player = nil; defaultPlayer?.stop(); defaultPlayer = nil }
}
