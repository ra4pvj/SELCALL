// Звонок при вызове на свой ID — повторяющиеся сигналы, как у трансиверов CODAN / Vertex Standard.
// Играет на выбранном устройстве (по умолчанию — системный выход Mac, не трансивер).

import AVFoundation
import CoreAudio
import Foundation

enum RingStyle: String, CaseIterable, Identifiable {
    case codan, vertex, beep
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codan: return "Двухтональный (как CODAN)"
        case .vertex: return "Трель (как Vertex)"
        case .beep: return "Короткие гудки"
        }
    }
}

final class Ringer {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var stopWork: DispatchWorkItem?
    private(set) var ringing = false

    /// Один период звонка (сигнал + пауза), моно.
    static func pattern(_ style: RingStyle, fs: Double, volume: Double) -> [Float] {
        var out = [Float]()
        func tone(_ f: Double, _ sec: Double) {
            let n = Int(sec * fs)
            let ramp = max(1, Int(0.004 * fs))
            for i in 0..<n {
                var a = volume
                if i < ramp { a *= Double(i) / Double(ramp) } else if i >= n - ramp { a *= Double(n - 1 - i) / Double(ramp) }
                out.append(Float(a * sin(2 * Double.pi * f * Double(i) / fs)))
            }
        }
        func silence(_ sec: Double) { out += [Float](repeating: 0, count: Int(sec * fs)) }
        switch style {
        case .codan:   // два тона попеременно ~0,8 с, пауза 1 с
            for _ in 0..<5 { tone(1000, 0.08); tone(1300, 0.08) }
            silence(1.0)
        case .vertex:  // быстрая трель, двойной «звонок», пауза
            for _ in 0..<2 {
                for _ in 0..<10 { tone(1500, 0.025); tone(2000, 0.025) }
                silence(0.2)
            }
            silence(1.4)
        case .beep:    // три гудка
            for _ in 0..<3 { tone(1200, 0.15); silence(0.1) }
            silence(1.0)
        }
        return out
    }

    /// Звонить до `seconds` секунд (или до stop()).
    func start(style: RingStyle, device: AudioDeviceID, volume: Double, seconds: Double) {
        stop()
        let e = AVAudioEngine()
        AudioDevices.select(device, on: e.outputNode)
        let p = AVAudioPlayerNode()
        e.attach(p)
        var fs = e.outputNode.outputFormat(forBus: 0).sampleRate
        if fs <= 0 { fs = 48000 }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: fs, channels: 1) else { return }
        e.connect(p, to: e.mainMixerNode, format: fmt)
        let x = Ringer.pattern(style, fs: fs, volume: volume)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count)),
              let ch = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: x.count) }
        do {
            e.prepare()
            try e.start()
        } catch { return }
        p.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
        p.play()
        engine = e
        player = p
        ringing = true
        let w = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, seconds), execute: w)
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        ringing = false
    }
}
