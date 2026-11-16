// Звуковая карта: список устройств (CoreAudio), приём (AVAudioEngine tap → 8 кГц),
// передача (AVAudioPlayerNode). Приём и передача — отдельные движки, чтобы
// вход и выход можно было выбрать на разных устройствах.

import AVFoundation
import CoreAudio
import Foundation
import ObjCSafe

/// Выполнить вызов AVAudioEngine, превращая NSException в Swift-ошибку.
func objcSafe(_ what: String, _ body: () throws -> Void) throws {
    var swiftError: Error?
    let reason = ObjCSafe.run {
        do { try body() } catch { swiftError = error }
    }
    if let r = reason { throw AudioIOError.engine("\(what): \(r)") }
    if let e = swiftError { throw e }
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let inputs: Int
    let outputs: Int
}

enum AudioDevices {
    static func all() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            AudioDevice(id: id, name: name(id),
                        inputs: channels(id, kAudioObjectPropertyScopeInput),
                        outputs: channels(id, kAudioObjectPropertyScopeOutput))
        }
    }

    static func name(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard st == noErr, let v = value else { return "Устройство \(id)" }
        return v.takeRetainedValue() as String
    }

    static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    @discardableResult
    static func select(_ device: AudioDeviceID, on node: AVAudioIONode) -> Bool {
        guard device != 0, let au = node.audioUnit else { return device == 0 }
        var dev = device
        let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        return st == noErr
    }
}

enum AudioIOError: LocalizedError {
    case noInput, converter, noPermission, engine(String)
    var errorDescription: String? {
        switch self {
        case .engine(let s): return s
        case .noInput: return "входное устройство недоступно"
        case .converter: return "не удалось создать преобразователь формата"
        case .noPermission: return "нет доступа к микрофону (Системные настройки → Конфиденциальность → Микрофон)"
        }
    }
}

final class AudioIO {
    static let rxRate = 8000.0

    private var rxEngine: AVAudioEngine?
    private var txEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var txRate: Double = 48000

    /// Вызывается с аудиопотока: моно-отсчёты 8 кГц и пиковый уровень выбранного канала (0…1).
    var onSamples: (([Float], Float) -> Void)?
    /// Время последнего блока со входа (для сторожевого таймера приёма). Уведомления macOS о
    /// «перестройке устройства» не используются: с USB-звуком (IC-705 и т.п.) они приходят
    /// постоянно, и перезапуск по ним зацикливался.
    private let sampleClock = NSLock()
    private var lastSampleAt = Date()
    var secondsSinceLastSample: TimeInterval {
        sampleClock.lock(); defer { sampleClock.unlock() }
        return Date().timeIntervalSince(lastSampleAt)
    }
    /// Канал входа: 0 — авто (канал с сигналом), 1, 2, … — номер канала устройства.
    var inputChannel = 0
    /// Какой канал реально используется (1…), и сколько каналов у входа.
    private(set) var activeChannel = 1
    private(set) var inputChannels = 1
    private var chEnergy = [Double]()

    static func requestMicAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    /// Запуск приёма. Возвращает предупреждение, если пришлось перейти на системный вход.
    @discardableResult
    func startRx(device: AudioDeviceID) throws -> String? {
        stopRx()
        do {
            try startRxOn(device: device)
            return nil
        } catch {
            // выбранное устройство не открылось — пробуем системный вход, чтобы не остаться без приёма
            guard device != 0 else { throw error }
            stopRx()
            try startRxOn(device: 0)
            return "Выбранный вход не открылся (\(error.localizedDescription)); включён системный вход по умолчанию"
        }
    }

    private func startRxOn(device: AudioDeviceID) throws {
        let engine = AVAudioEngine()
        var input: AVAudioInputNode!
        try objcSafe("вход") { input = engine.inputNode }
        AudioDevices.select(device, on: input)
        // формат берём с самого устройства (inputFormat шины 0); outputFormat после смены
        // устройства может остаться старым — из-за этого installTap падал с исключением
        let hw = input.inputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else { throw AudioIOError.noInput }
        guard let inFmt = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: hw.channelCount),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rxRate,
                                         channels: 1, interleaved: false) else { throw AudioIOError.converter }
        inputChannels = Int(hw.channelCount)
        chEnergy = [Double](repeating: 0, count: inputChannels)
        // Берём ОДИН канал, а не среднее всех: у стерео-интерфейса (Scarlett и т.п.) трансивер обычно
        // подключён к одному входу, и усреднение с пустым каналом занижало сигнал вдвое.
        var conv: AVAudioConverter?
        var monoFmt: AVAudioFormat?
        let tap: AVAudioNodeTapBlock = { [weak self] buf, _ in
            guard let self = self, let src = buf.floatChannelData, buf.frameLength > 0 else { return }
            let n = Int(buf.frameLength)
            let nch = Int(buf.format.channelCount)
            if nch != self.chEnergy.count { self.chEnergy = [Double](repeating: 0, count: nch); self.inputChannels = nch }
            // выбор канала
            var sel = 0
            if self.inputChannel > 0 {
                sel = min(self.inputChannel, nch) - 1
            } else if nch > 1 {
                for c in 0..<nch {
                    var e = 0.0
                    let p = src[c]
                    for i in stride(from: 0, to: n, by: 4) { e += Double(p[i] * p[i]) }
                    self.chEnergy[c] = self.chEnergy[c] * 0.9 + e / Double(max(1, n / 4))
                }
                let best = self.chEnergy.indices.max(by: { self.chEnergy[$0] < self.chEnergy[$1] }) ?? 0
                let cur = self.activeChannel - 1
                // гистерезис: переключаемся, только если другой канал заметно громче
                sel = (cur < nch && self.chEnergy[cur] * 2 >= self.chEnergy[best]) ? cur : best
            }
            self.activeChannel = sel + 1
            let p = src[sel]
            var peak: Float = 0
            for i in 0..<n { peak = max(peak, abs(p[i])) }
            // канал -> моно-буфер -> 8 кГц
            if monoFmt == nil || monoFmt!.sampleRate != buf.format.sampleRate {
                monoFmt = AVAudioFormat(standardFormatWithSampleRate: buf.format.sampleRate, channels: 1)
                conv = monoFmt.flatMap { AVAudioConverter(from: $0, to: outFmt) }
            }
            guard let mf = monoFmt, let cv = conv,
                  let mono = AVAudioPCMBuffer(pcmFormat: mf, frameCapacity: AVAudioFrameCount(n)),
                  let md = mono.floatChannelData else { return }
            mono.frameLength = AVAudioFrameCount(n)
            md[0].update(from: p, count: n)
            let cap = AVAudioFrameCount(Double(n) * Self.rxRate / mf.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            cv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return mono
            }
            guard err == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return }
            let x = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            self.sampleClock.lock(); self.lastSampleAt = Date(); self.sampleClock.unlock()
            self.onSamples?(x, peak)
        }
        do {
            try objcSafe("подключение ко входу") {
                input.installTap(onBus: 0, bufferSize: 4096, format: inFmt, block: tap)
            }
        } catch {
            // запасной вариант: формат по умолчанию самого узла
            _ = ObjCSafe.run { input.removeTap(onBus: 0) }
            try objcSafe("подключение ко входу") {
                input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: tap)
            }
        }
        try objcSafe("запуск приёма") {
            engine.prepare()
            try engine.start()
        }
        rxEngine = engine
        sampleClock.lock(); lastSampleAt = Date(); sampleClock.unlock()
    }

    func stopRx() {
        if let e = rxEngine {
            _ = ObjCSafe.run {
                e.inputNode.removeTap(onBus: 0)
                e.stop()
            }
        }
        rxEngine = nil
    }

    var isReceiving: Bool { rxEngine?.isRunning ?? false }

    /// Подготовить движок передачи на выбранном устройстве. Возвращает частоту выхода.
    @discardableResult
    func prepareTx(device: AudioDeviceID) throws -> Double {
        stopTx()
        let engine = AVAudioEngine()
        AudioDevices.select(device, on: engine.outputNode)
        let p = AVAudioPlayerNode()
        engine.attach(p)
        let hwRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        txRate = hwRate > 0 ? hwRate : 48000
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: txRate, channels: 1) else {
            throw AudioIOError.converter
        }
        try objcSafe("выход") {
            engine.connect(p, to: engine.mainMixerNode, format: fmt)
            engine.prepare()
            try engine.start()
        }
        txEngine = engine
        player = p
        return txRate
    }

    var outputRate: Double { txRate }

    /// Проиграть отсчёты (частота = outputRate). `done` вызывается на главном потоке.
    func play(_ samples: [Float], done: @escaping () -> Void) {
        guard let p = player, let e = txEngine,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: txRate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData else { done(); return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            ch[0].update(from: src.baseAddress!, count: samples.count)
        }
        let r = ObjCSafe.run {
            if !e.isRunning { try? e.start() }
            p.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                DispatchQueue.main.async { done() }
            }
            p.play()
        }
        if r != nil { done() }
    }

    func stopTx() {
        let p = player, e = txEngine
        _ = ObjCSafe.run {
            p?.stop()
            e?.stop()
        }
        player = nil
        txEngine = nil
    }
}
