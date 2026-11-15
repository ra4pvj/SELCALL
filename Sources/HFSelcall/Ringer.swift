// Звонок и самоконтроль: вывод звука сразу на несколько устройств
// (например, динамики ноутбука при трансивере на внешней звуковой карте).

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

/// Звонок при вызове на свой ID — повторяющиеся сигналы, как у трансиверов CODAN / Vertex Standard.
/// Играет одновременно на всех переданных устройствах (0 = системный выход).
final class Ringer {
    private var engines: [AVAudioEngine] = []
    private var stopWork: DispatchWorkItem?
    var ringing: Bool { !engines.isEmpty }

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

    func start(style: RingStyle, devices: [AudioDeviceID], volume: Double, seconds: Double) {
        stop()
        for dev in (devices.isEmpty ? [AudioDeviceID(0)] : devices) {
            let e = AVAudioEngine()
            AudioDevices.select(dev, on: e.outputNode)
            let p = AVAudioPlayerNode()
            e.attach(p)
            var fs = e.outputNode.outputFormat(forBus: 0).sampleRate
            if fs <= 0 { fs = 48000 }
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: fs, channels: 1) else { continue }
            e.connect(p, to: e.mainMixerNode, format: fmt)
            let x = Ringer.pattern(style, fs: fs, volume: volume)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count)),
                  let ch = buf.floatChannelData else { continue }
            buf.frameLength = AVAudioFrameCount(x.count)
            x.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: x.count) }
            do {
                e.prepare()
                try e.start()
            } catch { continue }
            p.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
            p.play()
            engines.append(e)
        }
        let w = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, seconds), execute: w)
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        for e in engines { e.stop() }
        engines.removeAll()
    }
}

/// Самоконтроль: звук эфира (вход, 8 кГц) и своей передачи на одно или несколько устройств
/// с отдельным уровнем. У каждого устройства свой AVAudioEngine с двумя плеерами (эфир, передача).
final class Monitor {
    private final class Out {
        let engine = AVAudioEngine()
        let rx = AVAudioPlayerNode()
        let tx = AVAudioPlayerNode()
        var queued = 0                         // буферов эфира в очереди (ограничиваем задержку)
        let lock = NSLock()
    }

    static let rate = 8000.0
    private var outs: [AudioDeviceID: Out] = [:]
    private let fmt = AVAudioFormat(standardFormatWithSampleRate: Monitor.rate, channels: 1)!
    private let lock = NSLock()
    private(set) var errors: [String] = []

    var level: Float = 0.5 {
        didSet {
            lock.lock(); defer { lock.unlock() }
            for o in outs.values { o.rx.volume = level; o.tx.volume = level }
        }
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !outs.isEmpty
    }

    func configure(devices: [AudioDeviceID], names: [AudioDeviceID: String]) {
        lock.lock(); defer { lock.unlock() }
        errors = []
        for (id, o) in outs where !devices.contains(id) {
            o.engine.stop()
            outs[id] = nil
        }
        for id in devices where outs[id] == nil {
            let o = Out()
            AudioDevices.select(id, on: o.engine.outputNode)
            o.engine.attach(o.rx)
            o.engine.attach(o.tx)
            o.engine.connect(o.rx, to: o.engine.mainMixerNode, format: fmt)
            o.engine.connect(o.tx, to: o.engine.mainMixerNode, format: fmt)
            o.rx.volume = level
            o.tx.volume = level
            do {
                o.engine.prepare()
                try o.engine.start()
                o.rx.play()
                o.tx.play()
                outs[id] = o
            } catch {
                errors.append("\(names[id] ?? "устройство \(id)"): \(error.localizedDescription)")
            }
        }
    }

    private func buffer(_ x: [Float]) -> AVAudioPCMBuffer? {
        guard !x.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count)),
              let ch = b.floatChannelData else { return nil }
        b.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: x.count) }
        return b
    }

    /// Эфир, 8 кГц, небольшими блоками (из аудиопотока приёма).
    func feedRX(_ x: [Float]) {
        lock.lock(); let list = Array(outs.values); lock.unlock()
        guard !list.isEmpty, let b = buffer(x) else { return }
        for o in list {
            o.lock.lock()
            let drop = o.queued > 6                 // ~0,5 с: не копим задержку
            if !drop { o.queued += 1 }
            o.lock.unlock()
            if drop { continue }
            o.rx.scheduleBuffer(b) { [weak o] in
                guard let o = o else { return }
                o.lock.lock(); o.queued -= 1; o.lock.unlock()
            }
        }
    }

    /// Своя передача целиком (уже в 8 кГц) — играет параллельно с выходом на трансивер.
    func feedTX(_ x8: [Float]) {
        lock.lock(); let list = Array(outs.values); lock.unlock()
        guard !list.isEmpty, let b = buffer(x8) else { return }
        for o in list { o.tx.scheduleBuffer(b, completionHandler: nil) }
    }

    func stopTX() {
        lock.lock(); let list = Array(outs.values); lock.unlock()
        for o in list {
            o.tx.stop()
            o.tx.play()
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        for o in outs.values { o.engine.stop() }
        outs.removeAll()
    }
}
