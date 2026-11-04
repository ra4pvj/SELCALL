// Звуковая карта: список устройств (CoreAudio), приём (AVAudioEngine tap → 8 кГц),
// передача (AVAudioPlayerNode). Приём и передача — отдельные движки, чтобы
// вход и выход можно было выбрать на разных устройствах.

import AVFoundation
import CoreAudio
import Foundation

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
    case noInput, converter, noPermission
    var errorDescription: String? {
        switch self {
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

    /// Вызывается с аудиопотока: моно-отсчёты 8 кГц и пиковый уровень.
    var onSamples: (([Float], Float) -> Void)?

    static func requestMicAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    func startRx(device: AudioDeviceID) throws {
        stopRx()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        AudioDevices.select(device, on: input)
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else { throw AudioIOError.noInput }
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rxRate,
                                         channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw AudioIOError.converter }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, _ in
            guard let self = self else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * Self.rxRate / inFmt.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            guard err == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return }
            let x = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            var peak: Float = 0
            for v in x { peak = max(peak, abs(v)) }
            self.onSamples?(x, peak)
        }
        engine.prepare()
        try engine.start()
        rxEngine = engine
    }

    func stopRx() {
        if let e = rxEngine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
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
        engine.connect(p, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        try engine.start()
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
        if !e.isRunning { try? e.start() }
        p.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async { done() }
        }
        p.play()
    }

    func stopTx() {
        player?.stop()
        txEngine?.stop()
        player = nil
        txEngine = nil
    }
}
