import AVFoundation
import Foundation

/// Synthesized alert chimes played through AVAudioEngine.
///
/// Two fixes over system sounds: (1) system sounds are silenced while the
/// capture session owns a record-mode audio session — this app's normal
/// state — so tones are generated PCM through the engine; (2) record mode
/// routes output to the EARPIECE by default, which is why earlier tones
/// were barely audible — playback here forces the speaker.
///
/// Design: pleasant two-note musical chimes, distinct per event, loud
/// enough for road noise without being harsh (soft attack, gentle release,
/// light second harmonic for warmth).
final class AlertSounds {
    enum Tone {
        case cyclist   // urgent rising pair (B5 → E6)
        case school    // soft descending pair (A5 → E5)
        case hospital  // gentle rising pair (E5 → A5)
        case hump      // low rising pair (A4 → C5)
        case city      // welcoming pair (C5 → E5)
        case fireStation // attention pair, warm not shrill (F5 → A5)
    }

    static let shared = AlertSounds()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var buffers: [Tone: AVAudioPCMBuffer] = [:]

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0

        buffers[.cyclist] = Self.render(notes: [(988, 0.16), (0, 0.03), (1319, 0.26)], format: format)
        buffers[.school] = Self.render(notes: [(880, 0.16), (0, 0.03), (659, 0.26)], format: format)
        buffers[.hospital] = Self.render(notes: [(659, 0.16), (0, 0.03), (880, 0.26)], format: format)
        buffers[.hump] = Self.render(notes: [(440, 0.16), (0, 0.03), (523, 0.24)], format: format)
        buffers[.city] = Self.render(notes: [(523, 0.16), (0, 0.03), (659, 0.26)], format: format)
        buffers[.fireStation] = Self.render(
            notes: [(698, 0.14), (0, 0.04), (880, 0.14), (0, 0.04), (698, 0.24)], format: format
        )
    }

    func play(_ tone: Tone) {
        guard let buffer = buffers[tone] else { return }
        do {
            // Record mode defaults to the earpiece; force the loud speaker.
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            if !engine.isRunning {
                try engine.start()
            }
            player.scheduleBuffer(buffer, at: nil)
            player.play()
        } catch {
            DiagLog.shared.error("Alert tone failed: \(error.localizedDescription)")
        }
    }

    /// Renders (frequency, duration) notes — frequency 0 is a rest — with a
    /// soft attack/release envelope and a light second harmonic.
    private static func render(
        notes: [(frequency: Double, duration: Double)],
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let totalFrames = AVAudioFrameCount(notes.reduce(0) { $0 + $1.duration } * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let samples = buffer.floatChannelData?[0] else { return nil }

        var frame = 0
        for note in notes {
            let noteFrames = Int(note.duration * sampleRate)
            for i in 0..<noteFrames {
                var value: Float = 0
                if note.frequency > 0 {
                    let t = Double(i) / sampleRate
                    let attack = min(1.0, Double(i) / (sampleRate * 0.02))
                    let release = min(1.0, Double(noteFrames - i) / (sampleRate * 0.06))
                    let envelope = min(attack, release)
                    let fundamental = sin(2 * .pi * note.frequency * t)
                    let harmonic = 0.3 * sin(4 * .pi * note.frequency * t)
                    value = Float((fundamental + harmonic) / 1.3 * envelope * 0.9)
                }
                samples[frame] = value
                frame += 1
            }
        }
        buffer.frameLength = AVAudioFrameCount(frame)
        return buffer
    }
}
