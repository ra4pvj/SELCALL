// Звонок и самоконтроль: вывод звука сразу на несколько устройств
// (например, динамики ноутбука при трансивере на внешней звуковой карте).

import AVFoundation
import CoreAudio
import Foundation
import ObjCSafe

enum RingStyle: String, CaseIterable, Identifiable {
    case codan, vertex, beep, kalinka
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codan: return "Двухтональный"
        case .vertex: return "Трель"
        case .beep: return "Короткие гудки"
        case .kalinka: return "Мелодия «Калинка»"
        }
    }
}

/// Начало припева «Калинки» (И. Ларионов, 1860; общественное достояние) по нотам, на октаву выше
/// записи: «ми ре си до ре си до ре до си ля» — E5 | D5 B4 C5 | D5 B4 C5 | D5 C5 B4 | A4.
/// (частота, Гц; длительность в четвертях, как в нотах: половинная = 2). 16 четвертей по 0,18 с ≈ 2,9 с.
enum Kalinka {
    static let E5 = 659.26, D5 = 587.33, C5 = 523.25, B4 = 493.88, A4 = 440.0
    static let quarter = 0.18
    static let notes: [(Double, Double)] = [
        (E5, 2),
        (D5, 2), (B4, 1), (C5, 1),
        (D5, 2), (B4, 1), (C5, 1),
        (D5, 2), (C5, 1), (B4, 1),
        (A4, 2),
    ]
}

/// Звонок при вызове на свой ID — повторяющиеся сигналы.
/// Играет одновременно на всех переданных устройствах (0 = системный выход).
final class Ringer {
    private var engines: [AVAudioEngine] = []
    private var stopWork: DispatchWorkItem?
    var ringing: Bool { !engines.isEmpty }

    /// Длительность сигнала ответа в эфир для звонков-«тонов» (мелодия звучит целиком один раз).
    static let answerSeconds = 2.5

    /// Сигнал ответа в эфир: мелодия — один раз без паузы; остальные сигналы — 2,5 с, конец плавно гасится.
    static func answer(_ style: RingStyle, fs: Double, volume: Double) -> [Float] {
        var x = pattern(style, fs: fs, volume: volume)
        if style == .kalinka {
            x.removeLast(min(x.count, Int(0.8 * fs)))              // без паузы после фразы
            return x
        }
        let n = Int(answerSeconds * fs)
        var out = [Float]()
        out.reserveCapacity(n)
        while out.count < n && !x.isEmpty { out += x.prefix(n - out.count) }
        let fade = min(out.count, Int(0.02 * fs))
        for i in 0..<fade { out[out.count - 1 - i] *= Float(i) / Float(max(1, fade)) }
        return out
    }

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
        case .kalinka: // мелодия: нота с мягкой атакой и затуханием, лёгкая вторая гармоника
            for (f, n) in Kalinka.notes {
                let dur = n * Kalinka.quarter
                let len = Int((dur - 0.015) * fs)
                for i in 0..<max(0, len) {
                    let t = Double(i) / fs
                    let att = min(1, t / 0.006)
                    let dec = exp(-1.2 * t / dur)
                    let rel = min(1, Double(len - 1 - i) / (0.006 * fs))
                    let a = volume * att * dec * rel
                    out.append(Float(a * (0.85 * sin(2 * Double.pi * f * t) + 0.15 * sin(4 * Double.pi * f * t))))
                }
                silence(0.015)
            }
            silence(0.8)
        }
        return out
    }

    /// Звонить по кругу до `seconds` секунд; `once` — проиграть один раз сигнал ответа (прослушивание).
    func start(style: RingStyle, devices: [AudioDeviceID], volume: Double, seconds: Double, once: Bool = false) {
        stop()
        for dev in (devices.isEmpty ? [AudioDeviceID(0)] : devices) {
            let e = AVAudioEngine()
            let p = AVAudioPlayerNode()
            var fs = 48000.0
            var fmt: AVAudioFormat?
            let err = ObjCSafe.run {
                AudioDevices.select(dev, on: e.outputNode)
                e.attach(p)
                let r = e.outputNode.outputFormat(forBus: 0).sampleRate
                if r > 0 { fs = r }
                fmt = AVAudioFormat(standardFormatWithSampleRate: fs, channels: 1)
                if let f = fmt { e.connect(p, to: e.mainMixerNode, format: f) }
            }
            guard err == nil, let f = fmt else { continue }
            let x = once ? Ringer.answer(style, fs: fs, volume: volume) : Ringer.pattern(style, fs: fs, volume: volume)
            guard let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(x.count)),
                  let ch = buf.floatChannelData else { continue }
            buf.frameLength = AVAudioFrameCount(x.count)
            x.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: x.count) }
            var ok = false
            _ = ObjCSafe.run {
                e.prepare()
                guard (try? e.start()) != nil else { return }
                p.scheduleBuffer(buf, at: nil, options: once ? [] : [.loops], completionHandler: nil)
                p.play()
                ok = true
            }
            if ok { engines.append(e) }
        }
        let w = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, seconds), execute: w)
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        for e in engines { _ = ObjCSafe.run { e.stop() } }
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
            _ = ObjCSafe.run { o.engine.stop() }
            outs[id] = nil
        }
        for id in devices where outs[id] == nil {
            let o = Out()
            let f = fmt
            var startError: Error?
            let ex = ObjCSafe.run {
                AudioDevices.select(id, on: o.engine.outputNode)
                o.engine.attach(o.rx)
                o.engine.attach(o.tx)
                o.engine.connect(o.rx, to: o.engine.mainMixerNode, format: f)
                o.engine.connect(o.tx, to: o.engine.mainMixerNode, format: f)
                o.rx.volume = level
                o.tx.volume = level
                o.engine.prepare()
                do { try o.engine.start() } catch { startError = error; return }
                o.rx.play()
                o.tx.play()
            }
            if let r = ex ?? startError?.localizedDescription {
                errors.append("\(names[id] ?? "устройство \(id)"): \(r)")
            } else {
                outs[id] = o
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
            let r = ObjCSafe.run {
                o.rx.scheduleBuffer(b) { [weak o] in
                    guard let o = o else { return }
                    o.lock.lock(); o.queued -= 1; o.lock.unlock()
                }
            }
            if r != nil { o.lock.lock(); o.queued -= 1; o.lock.unlock() }
        }
    }

    /// Своя передача целиком (уже в 8 кГц) — играет параллельно с выходом на трансивер.
    func feedTX(_ x8: [Float]) {
        lock.lock(); let list = Array(outs.values); lock.unlock()
        guard !list.isEmpty, let b = buffer(x8) else { return }
        for o in list { _ = ObjCSafe.run { o.tx.scheduleBuffer(b, completionHandler: nil) } }
    }

    func stopTX() {
        lock.lock(); let list = Array(outs.values); lock.unlock()
        for o in list {
            _ = ObjCSafe.run {
                o.tx.stop()
                o.tx.play()
            }
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        for o in outs.values { _ = ObjCSafe.run { o.engine.stop() } }
        outs.removeAll()
    }
}
