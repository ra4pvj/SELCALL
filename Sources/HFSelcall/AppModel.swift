// Состояние приложения: настройки, журнал, приём/передача, PTT, звонок.

import AppKit
import AVFoundation
import Foundation
import SelcallCore
import UniformTypeIdentifiers

struct LogEntry: Identifiable {
    enum Kind { case rx, tx, info, error }
    let id = UUID()
    let date: Date
    let kind: Kind
    let from: String
    let to: String
    let title: String
    let text: String
    let detail: String
    let ok: Bool
}

final class AppModel: ObservableObject {
    // настройки (сохраняются)
    @Published var myID: String { didSet { defaults.set(myID, forKey: "myID") } }
    @Published var dotSeconds: Double { didSet { defaults.set(dotSeconds, forKey: "dotSeconds") } }
    @Published var txLevel: Double { didSet { defaults.set(txLevel, forKey: "txLevel") } }
    // трансивер (PTT)
    @Published var pttMode: PTTMode { didSet { defaults.set(pttMode.rawValue, forKey: "pttMode"); reopenPTT() } }
    @Published var pttPort: String { didSet { defaults.set(pttPort, forKey: "pttPort"); reopenPTT() } }
    @Published var pttDelay: Double { didSet { defaults.set(pttDelay, forKey: "pttDelay") } }
    @Published var pttTail: Double { didSet { defaults.set(pttTail, forKey: "pttTail") } }
    @Published var muteRxOnTx: Bool { didSet { defaults.set(muteRxOnTx, forKey: "muteRxOnTx") } }
    // звонок
    @Published var ringEnabled: Bool { didSet { defaults.set(ringEnabled, forKey: "ringEnabled") } }
    @Published var ringStyle: RingStyle { didSet { defaults.set(ringStyle.rawValue, forKey: "ringStyle") } }
    @Published var ringDevice: AudioDeviceID { didSet { defaults.set(Int(ringDevice), forKey: "ringDev") } }
    @Published var ringVolume: Double { didSet { defaults.set(ringVolume, forKey: "ringVolume") } }
    @Published var ringSeconds: Double { didSet { defaults.set(ringSeconds, forKey: "ringSeconds") } }
    @Published var transliterate: Bool { didSet { defaults.set(transliterate, forKey: "translit") } }
    @Published var autoAFC: Bool { didSet { defaults.set(autoAFC, forKey: "autoAFC"); applyCenter() } }
    @Published var fixedCenter: Double { didSet { defaults.set(fixedCenter, forKey: "fixedCenter"); applyCenter() } }
    @Published var showAll: Bool { didSet { defaults.set(showAll, forKey: "showAll") } }
    @Published var inputDevice: AudioDeviceID { didSet { defaults.set(Int(inputDevice), forKey: "inDev"); if receiving { startRx() } } }
    @Published var outputDevice: AudioDeviceID { didSet { defaults.set(Int(outputDevice), forKey: "outDev"); txReady = false } }

    // поля отправки
    @Published var toID: String = ""
    @Published var messageText: String = ""

    // состояние
    @Published var log: [LogEntry] = []
    @Published var level: Float = 0
    @Published var centers: [Double] = []
    @Published var receiving = false
    @Published var transmitting = false
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var pttPorts: [String] = []
    @Published var pttKeyed = false
    /// Входящий вызов, по которому сейчас звонит звонок (баннер в окне).
    @Published var incoming: LogEntry?

    private let defaults = UserDefaults.standard
    private let audio = AudioIO()
    private let dsp = DispatchQueue(label: "selcall.dsp", qos: .userInitiated)
    private var receiver = Receiver(sampleRate: AudioIO.rxRate)
    private var rxStart = Date()
    private var timer: DispatchSourceTimer?
    private var txReady = false
    private var muteUntil = Date.distantPast         // не декодировать собственную передачу
    private var txQueue: [(samples: [Float], entry: LogEntry)] = []
    private let ptt = SerialPTT()
    private let ringer = Ringer()
    private var watchdog: DispatchWorkItem?

    init() {
        myID = defaults.string(forKey: "myID") ?? "1234"
        dotSeconds = defaults.object(forKey: "dotSeconds") as? Double ?? 6.0
        txLevel = defaults.object(forKey: "txLevel") as? Double ?? 0.5
        pttMode = PTTMode(rawValue: defaults.string(forKey: "pttMode") ?? "") ?? .vox
        pttPort = defaults.string(forKey: "pttPort") ?? ""
        pttDelay = defaults.object(forKey: "pttDelay") as? Double ?? 0.5
        pttTail = defaults.object(forKey: "pttTail") as? Double ?? 0.3
        muteRxOnTx = defaults.object(forKey: "muteRxOnTx") as? Bool ?? true
        ringEnabled = defaults.object(forKey: "ringEnabled") as? Bool ?? true
        ringStyle = RingStyle(rawValue: defaults.string(forKey: "ringStyle") ?? "") ?? .codan
        ringDevice = AudioDeviceID(defaults.integer(forKey: "ringDev"))
        ringVolume = defaults.object(forKey: "ringVolume") as? Double ?? 0.5
        ringSeconds = defaults.object(forKey: "ringSeconds") as? Double ?? 30
        transliterate = defaults.object(forKey: "translit") as? Bool ?? true
        autoAFC = defaults.object(forKey: "autoAFC") as? Bool ?? true
        fixedCenter = defaults.object(forKey: "fixedCenter") as? Double ?? Selcall.defaultCenter
        showAll = defaults.object(forKey: "showAll") as? Bool ?? true
        inputDevice = AudioDeviceID(defaults.integer(forKey: "inDev"))
        outputDevice = AudioDeviceID(defaults.integer(forKey: "outDev"))
        refreshDevices()
        audio.onSamples = { [weak self] x, peak in self?.onSamples(x, peak) }
        reopenPTT()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.ptt.close()
            self?.ringer.stop()
        }
    }

    // MARK: устройства

    func refreshDevices() {
        let all = AudioDevices.all()
        inputDevices = all.filter { $0.inputs > 0 }
        outputDevices = all.filter { $0.outputs > 0 }
        if inputDevice != 0, !inputDevices.contains(where: { $0.id == inputDevice }) { inputDevice = 0 }
        if outputDevice != 0, !outputDevices.contains(where: { $0.id == outputDevice }) { outputDevice = 0 }
        if ringDevice != 0, !outputDevices.contains(where: { $0.id == ringDevice }) { ringDevice = 0 }
        pttPorts = SerialPTT.ports()
    }

    // MARK: PTT

    private func reopenPTT() {
        guard pttMode.usesPort else { ptt.close(); pttKeyed = false; return }
        guard !pttPort.isEmpty else { ptt.close(); return }
        do {
            try ptt.open(pttPort)
        } catch {
            addError("PTT: \(error.localizedDescription)")
        }
    }

    private func keyPTT(_ on: Bool) {
        guard pttMode.usesPort else { pttKeyed = on; return }
        do {
            if !ptt.isOpen { try ptt.open(pttPort) }
            try ptt.set(on, lines: pttMode.lines)
            pttKeyed = on
        } catch {
            ptt.release()
            pttKeyed = false
            if on { addError("PTT: \(error.localizedDescription)") }
        }
    }

    /// Проверка PTT: включить передачу на 1 секунду без сигнала.
    func testPTT() {
        guard !transmitting else { return }
        guard pttMode.usesPort else { addInfo("Режим VOX: трансивер управляется звуком, проверять нечего"); return }
        keyPTT(true)
        guard pttKeyed else { return }
        addInfo("Проверка PTT: \(pttPort), \(pttMode.title) — 1 с")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, !self.transmitting else { return }
            self.keyPTT(false)
        }
    }

    // MARK: звонок

    func stopRing() {
        ringer.stop()
        incoming = nil
    }

    func answerRing() {
        if let e = incoming { toID = e.from }
        stopRing()
    }

    func testRing() {
        ringer.start(style: ringStyle, device: ringDevice, volume: ringVolume, seconds: 4)
    }

    // MARK: приём

    func toggleRx() { receiving ? stopRx() : startRx() }

    func startRx() {
        AudioIO.requestMicAccess { [weak self] ok in
            guard let self = self else { return }
            guard ok else { self.addError(AudioIOError.noPermission.localizedDescription); return }
            do {
                try self.audio.startRx(device: self.inputDevice)
                self.dsp.sync {
                    self.receiver.reset()
                }
                self.rxStart = Date()
                self.applyCenter()
                self.receiving = true
                self.startTimer()
                self.addInfo("Приём запущен")
            } catch {
                self.receiving = false
                self.addError("Не удалось запустить приём: \(error.localizedDescription)")
            }
        }
    }

    func stopRx() {
        audio.stopRx()
        timer?.cancel()
        timer = nil
        receiving = false
        level = 0
    }

    private func applyCenter() {
        let c: Double? = autoAFC ? nil : fixedCenter
        dsp.async { self.receiver.fixedCenter = c }
    }

    private func onSamples(_ x: [Float], _ peak: Float) {
        let muted = Date() < muteUntil
        dsp.async {
            self.receiver.append(muted ? [Float](repeating: 0, count: x.count) : x)
        }
        DispatchQueue.main.async { self.level = self.level * 0.6 + peak * 0.4 }
    }

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: dsp)
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let calls = self.receiver.process()
            let centers = self.receiver.lastCenters
            let start = self.rxStart
            DispatchQueue.main.async {
                self.centers = centers
                for c in calls { self.handleRx(c, date: start.addingTimeInterval(c.time)) }
            }
        }
        t.resume()
        timer = t
    }

    private func handleRx(_ c: DecodedCall, date: Date, fromFile: Bool = false) {
        let mine = Selcall.digitsOnly(c.to) == Selcall.digitsOnly(myID).leftPadded(to: c.to.count)
        let own = !fromFile && Selcall.digitsOnly(c.from) == Selcall.digitsOnly(myID).leftPadded(to: c.from.count)
        if !showAll && !mine && !fromFile { return }
        let title: String
        switch (c.isMessage, c.eos) {
        case (_, Selcall.eosAckBQ): title = "Подтверждение"
        case (true, _): title = "Сообщение"
        default: title = "Вызов"
        }
        let detail = String(format: "fmt %d · cat %d · %@ · ECC %@ · %@ · %.1f Гц%@%@",
                            c.format, c.category, c.eosName, c.ecc, c.eccOK ? "принят" : "СОМНИТЕЛЬНО", c.center,
                            c.inverted ? " · LSB" : "", c.conflicts > 0 ? " · исправлено \(c.conflicts)" : "")
        let entry = LogEntry(date: date, kind: .rx, from: c.from, to: c.to,
                             title: own ? "Своя передача (эхо)" :
                                 title + (mine ? " мне" : "") + (fromFile ? " (файл)" : ""),
                             text: c.message, detail: detail, ok: c.eccOK)
        log.append(entry)
        if mine, !own, !fromFile, c.eccOK, c.eos != Selcall.eosAckBQ {
            incoming = entry
            NSApp.requestUserAttention(.criticalRequest)
            if ringEnabled {
                ringer.start(style: ringStyle, device: ringDevice, volume: ringVolume, seconds: ringSeconds)
            }
        }
    }

    // MARK: передача

    func sendSelcall() { send(to: toID, message: nil, eos: Selcall.eosAckRQ, title: "Вызов") }

    func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        send(to: toID, message: messageText, eos: Selcall.eosAckRQ, title: "Сообщение")
        messageText = ""
    }

    private func prepared(_ message: String?) -> String? {
        guard let m = message, !m.isEmpty else { return nil }
        return String((transliterate ? Translit.latin(m) : m).prefix(Selcall.maxMessage))
    }

    private func validIDs(_ to: String) -> Bool {
        let t = Selcall.digitsOnly(to), f = Selcall.digitsOnly(myID)
        guard !t.isEmpty, !f.isEmpty, t.count <= 10, f.count <= 10 else {
            addError("Укажите цифровые ID: свой и получателя (4 или 6 цифр)")
            return false
        }
        return true
    }

    private func send(to: String, message: String?, eos: Int, title: String) {
        guard validIDs(to) else { return }
        do {
            if !txReady {
                try audio.prepareTx(device: outputDevice)
                txReady = true
            }
        } catch {
            addError("Не удалось открыть выход: \(error.localizedDescription)")
            return
        }
        let text = prepared(message)
        let stream = Selcall.buildCall(to: to, from: myID, message: text, eos: eos)
        let rate = audio.outputRate
        let y = [Float](repeating: 0, count: Int(pttDelay * rate))
            + Selcall.modulate(stream, sampleRate: rate, dotSeconds: dotSeconds, amplitude: txLevel)
            + [Float](repeating: 0, count: Int(pttTail * rate))
        let entry = LogEntry(date: Date(), kind: .tx, from: Selcall.digitsOnly(myID), to: Selcall.digitsOnly(to),
                             title: title, text: text ?? "",
                             detail: String(format: "%.1f с · %@", Double(y.count) / audio.outputRate,
                                            Selcall.eosName(eos)), ok: true)
        txQueue.append((y, entry))
        if !transmitting { playNext() }
    }

    private func playNext() {
        guard !txQueue.isEmpty else { finishTx(); return }
        let item = txQueue.removeFirst()
        transmitting = true
        log.append(item.entry)
        let dur = Double(item.samples.count) / audio.outputRate
        if muteRxOnTx { muteUntil = Date().addingTimeInterval(dur + 1.0) }
        keyPTT(true)
        // страховка: PTT снимается, даже если звук «завис»
        watchdog?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.transmitting else { return }
            self.addError("Передача не завершилась вовремя — PTT снят принудительно")
            self.stopTx()
        }
        watchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + dur + 5, execute: w)
        audio.play(item.samples) { [weak self] in
            guard let self = self, self.transmitting else { return }
            self.playNext()
        }
    }

    private func finishTx() {
        watchdog?.cancel()
        watchdog = nil
        keyPTT(false)
        transmitting = false
        if muteRxOnTx { muteUntil = Date().addingTimeInterval(0.5) }
    }

    func stopTx() {
        txQueue.removeAll()
        audio.stopTx()
        txReady = false
        finishTx()
        ptt.release()
        muteUntil = Date()
    }

    // MARK: файлы

    func saveWAV(message: Bool) {
        guard validIDs(toID) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.wav]
        panel.nameFieldStringValue = "selcall_\(Selcall.digitsOnly(myID))_to_\(Selcall.digitsOnly(toID)).wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let stream = Selcall.buildCall(to: toID, from: myID, message: message ? prepared(messageText) : nil)
        let y = Selcall.modulate(stream, sampleRate: 48000, dotSeconds: dotSeconds, amplitude: txLevel)
        do {
            try WAV.write(url, samples: y, sampleRate: 48000)
            addInfo("Сохранено: \(url.lastPathComponent)")
        } catch {
            addError("Ошибка записи WAV: \(error.localizedDescription)")
        }
    }

    func openWAV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.wav, UTType.audio]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { decodeFile(url) }
    }

    func decodeFile(_ url: URL) {
        addInfo("Декодирую \(url.lastPathComponent)…")
        let center: Double? = autoAFC ? nil : fixedCenter
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let (x, fs) = try Self.readAudio(url)
                let x8 = Resampler.resample(x, from: fs, to: AudioIO.rxRate)
                let calls = Selcall.decode(x8, fs: AudioIO.rxRate, center: center)
                DispatchQueue.main.async {
                    if calls.isEmpty { self.addInfo("\(url.lastPathComponent): вызовов не найдено") }
                    for c in calls { self.handleRx(c, date: Date(), fromFile: true) }
                }
            } catch {
                DispatchQueue.main.async { self.addError("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
    }

    /// WAV читаем своим парсером, остальное (AIFF, MP3, M4A, FLAC…) — через AVAudioFile.
    static func readAudio(_ url: URL) throws -> ([Float], Double) {
        if let r = try? WAV.read(url) { return (r.samples, r.sampleRate) }
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else {
            throw AudioIOError.converter
        }
        try f.read(into: buf)
        guard let ch = buf.floatChannelData else { throw AudioIOError.converter }
        return (Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength))), fmt.sampleRate)
    }

    // MARK: журнал

    func clearLog() { log.removeAll() }

    func addInfo(_ s: String) {
        log.append(LogEntry(date: Date(), kind: .info, from: "", to: "", title: s, text: "", detail: "", ok: true))
    }

    func addError(_ s: String) {
        log.append(LogEntry(date: Date(), kind: .error, from: "", to: "", title: s, text: "", detail: "", ok: false))
    }

    func reply(to entry: LogEntry) {
        if !entry.from.isEmpty { toID = entry.from }
    }
}

extension String {
    func leftPadded(to n: Int) -> String {
        count >= n ? self : String(repeating: "0", count: n - count) + self
    }
}
