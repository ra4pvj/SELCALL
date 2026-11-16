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
    // управление передачей (PTT / CAT, как в HFP)
    @Published var pttMethod: PTTMethod {
        didSet {
            defaults.set(pttMethod.rawValue, forKey: "pttMethod")
            if oldValue != pttMethod { pttBaud = pttMethod.defaultBaud }
            reopenPTT()
        }
    }
    @Published var pttPort: String { didSet { defaults.set(pttPort, forKey: "pttPort"); reopenPTT() } }
    @Published var pttBaud: Int { didSet { defaults.set(pttBaud, forKey: "pttBaud"); reopenPTT() } }
    @Published var pttInvert: Bool { didSet { defaults.set(pttInvert, forKey: "pttInvert"); reopenPTT() } }
    @Published var icomModel: String {
        didSet {
            defaults.set(icomModel, forKey: "icomModel")
            if let a = PTTCat.icomModels.first(where: { $0.name == icomModel })?.addr {
                icomAddr = String(format: "%02X", a)
            }
        }
    }
    @Published var icomAddr: String { didSet { defaults.set(icomAddr, forKey: "icomAddr"); reopenPTT() } }
    @Published var kenwoodVariant: String { didSet { defaults.set(kenwoodVariant, forKey: "kenwood"); reopenPTT() } }
    @Published var pttDelay: Double { didSet { defaults.set(pttDelay, forKey: "pttDelay") } }
    @Published var pttTail: Double { didSet { defaults.set(pttTail, forKey: "pttTail") } }
    @Published var muteRxOnTx: Bool { didSet { defaults.set(muteRxOnTx, forKey: "muteRxOnTx") } }
    // звонок
    @Published var ringEnabled: Bool { didSet { defaults.set(ringEnabled, forKey: "ringEnabled") } }
    @Published var ringStyle: RingStyle { didSet { defaults.set(ringStyle.rawValue, forKey: "ringStyle") } }
    // внешнее устройство: «1» на линии COM-порта при вызове на мой ID
    @Published var extEnabled: Bool { didSet { defaults.set(extEnabled, forKey: "extEnabled") } }
    @Published var extPort: String { didSet { defaults.set(extPort, forKey: "extPort"); extReset() } }
    @Published var extLine: ExtLine { didSet { defaults.set(extLine.rawValue, forKey: "extLine"); extReset() } }
    @Published var extInvert: Bool { didSet { defaults.set(extInvert, forKey: "extInvert"); extReset() } }
    @Published var extSeconds: Double { didSet { defaults.set(extSeconds, forKey: "extSeconds") } }
    @Published var extOn = false            // выход сейчас включён
    @Published var extManual = false        // включён вручную (без таймера)
    /// Сигнал ответа в эфир — выбирается отдельно от звонка.
    @Published var answerStyle: RingStyle { didSet { defaults.set(answerStyle.rawValue, forKey: "answerStyle") } }
    // самоконтроль: эфир и своя передача на одно или несколько устройств
    @Published var monitorDevices: [String] { didSet { defaults.set(monitorDevices, forKey: "monDevs"); applyMonitor() } }
    @Published var monitorRX: Bool { didSet { defaults.set(monitorRX, forKey: "monRX"); applyMonitor() } }
    @Published var monitorTX: Bool { didSet { defaults.set(monitorTX, forKey: "monTX"); applyMonitor() } }
    @Published var monitorLevel: Double { didSet { defaults.set(monitorLevel, forKey: "monLevel"); monitor.level = Float(monitorLevel) } }
    @Published var ringVolume: Double { didSet { defaults.set(ringVolume, forKey: "ringVolume") } }
    @Published var ringSeconds: Double { didSet { defaults.set(ringSeconds, forKey: "ringSeconds") } }
    /// Ответный звонок в эфир (как у CODAN / Vertex): вызывающая станция слышит, что вызов принят.
    @Published var ringOnAir: Bool { didSet { defaults.set(ringOnAir, forKey: "ringOnAir") } }
    @Published var transliterate: Bool { didSet { defaults.set(transliterate, forKey: "translit") } }
    @Published var autoAFC: Bool { didSet { defaults.set(autoAFC, forKey: "autoAFC"); applyCenter() } }
    @Published var fixedCenter: Double { didSet { defaults.set(fixedCenter, forKey: "fixedCenter"); applyCenter() } }
    @Published var showAll: Bool { didSet { defaults.set(showAll, forKey: "showAll") } }
    /// Канал входа: 0 — авто, 1 — левый, 2 — правый …
    @Published var inputChannel: Int { didSet { defaults.set(inputChannel, forKey: "inChannel"); audio.inputChannel = inputChannel } }
    @Published var activeChannel = 1
    @Published var inputChannels = 1
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
    private let ptt = PTTController()
    private let ringer = Ringer()
    private let monitor = Monitor()
    private let ext = ExtControl()
    private var extTimer: DispatchWorkItem?
    private var watchdog: DispatchWorkItem?

    init() {
        myID = defaults.string(forKey: "myID") ?? "1234"
        dotSeconds = defaults.object(forKey: "dotSeconds") as? Double ?? 6.0
        txLevel = defaults.object(forKey: "txLevel") as? Double ?? 0.5
        // миграция настроек 0.3-dev: pttMode vox/rts/dtr/both
        let legacy: [String: PTTMethod] = ["rts": .rts, "dtr": .dtr, "both": .rtsDtr, "vox": PTTMethod.none]
        pttMethod = PTTMethod(rawValue: defaults.string(forKey: "pttMethod") ?? "")
            ?? legacy[defaults.string(forKey: "pttMode") ?? ""] ?? PTTMethod.none
        pttPort = defaults.string(forKey: "pttPort") ?? ""
        pttBaud = defaults.object(forKey: "pttBaud") as? Int ?? 9600
        pttInvert = defaults.bool(forKey: "pttInvert")
        icomModel = defaults.string(forKey: "icomModel") ?? "IC-7300"
        icomAddr = defaults.string(forKey: "icomAddr") ?? "94"
        kenwoodVariant = defaults.string(forKey: "kenwood") ?? "TX;"
        monitorDevices = defaults.stringArray(forKey: "monDevs") ?? []
        monitorRX = defaults.object(forKey: "monRX") as? Bool ?? true
        monitorTX = defaults.object(forKey: "monTX") as? Bool ?? true
        monitorLevel = defaults.object(forKey: "monLevel") as? Double ?? 0.5
        pttDelay = defaults.object(forKey: "pttDelay") as? Double ?? 0.5
        pttTail = defaults.object(forKey: "pttTail") as? Double ?? 0.3
        muteRxOnTx = defaults.object(forKey: "muteRxOnTx") as? Bool ?? true
        ringEnabled = defaults.object(forKey: "ringEnabled") as? Bool ?? true
        ringStyle = RingStyle(rawValue: defaults.string(forKey: "ringStyle") ?? "") ?? .codan
        answerStyle = RingStyle(rawValue: defaults.string(forKey: "answerStyle") ?? "") ?? .kalinka
        extEnabled = defaults.bool(forKey: "extEnabled")
        extPort = defaults.string(forKey: "extPort") ?? ""
        extLine = ExtLine(rawValue: defaults.string(forKey: "extLine") ?? "") ?? .dtr
        extInvert = defaults.bool(forKey: "extInvert")
        extSeconds = defaults.object(forKey: "extSeconds") as? Double ?? 5
        ringVolume = defaults.object(forKey: "ringVolume") as? Double ?? 0.5
        ringSeconds = defaults.object(forKey: "ringSeconds") as? Double ?? 30
        ringOnAir = defaults.object(forKey: "ringOnAir") as? Bool ?? true
        transliterate = defaults.object(forKey: "translit") as? Bool ?? true
        autoAFC = defaults.object(forKey: "autoAFC") as? Bool ?? true
        fixedCenter = defaults.object(forKey: "fixedCenter") as? Double ?? Selcall.defaultCenter
        showAll = defaults.object(forKey: "showAll") as? Bool ?? true
        inputChannel = defaults.integer(forKey: "inChannel")
        inputDevice = AudioDeviceID(defaults.integer(forKey: "inDev"))
        outputDevice = AudioDeviceID(defaults.integer(forKey: "outDev"))
        refreshDevices()
        audio.inputChannel = inputChannel
        audio.onSamples = { [weak self] x, peak in self?.onSamples(x, peak) }
        reopenPTT()
        monitor.level = Float(monitorLevel)
        applyMonitor()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.ptt.unkeySafe()
            self?.ptt.close()
            if let m = self { m.ext.close(line: m.extLine, invert: m.extInvert) }
            self?.ringer.stop()
            self?.monitor.close()
        }
    }

    // MARK: устройства

    func refreshDevices() {
        let all = AudioDevices.all()
        inputDevices = all.filter { $0.inputs > 0 }
        outputDevices = all.filter { $0.outputs > 0 }
        if inputDevice != 0, !inputDevices.contains(where: { $0.id == inputDevice }) { inputDevice = 0 }
        if outputDevice != 0, !outputDevices.contains(where: { $0.id == outputDevice }) { outputDevice = 0 }
        pttPorts = PTTController.ports()
    }

    // MARK: самоконтроль

    /// ID выбранных устройств самоконтроля (по имени; отсутствующие пропускаются).
    var monitorDeviceIDs: [AudioDeviceID] {
        monitorDevices.compactMap { n in outputDevices.first(where: { $0.name == n })?.id }
    }

    func isMonitorDevice(_ d: AudioDevice) -> Bool { monitorDevices.contains(d.name) }

    func setMonitorDevice(_ d: AudioDevice, _ on: Bool) {
        if on, !monitorDevices.contains(d.name) { monitorDevices.append(d.name) }
        if !on { monitorDevices.removeAll { $0 == d.name } }
    }

    private func applyMonitor() {
        let ids = (monitorRX || monitorTX) ? monitorDeviceIDs : []
        var names = [AudioDeviceID: String]()
        for d in outputDevices { names[d.id] = d.name }
        monitor.configure(devices: ids, names: names)
        for e in monitor.errors { addError("Самоконтроль: \(e)") }
    }

    // MARK: PTT / CAT

    var pttConfig: PTTConfig {
        PTTConfig(method: pttMethod, port: pttPort, baud: pttBaud, invert: pttInvert,
                  icomAddr: PTTCat.parseHexAddr(icomAddr) ?? 0x94, kenwood: kenwoodVariant)
    }

    private func reopenPTT() {
        guard pttMethod.usesPort, !pttPort.isEmpty else {
            ptt.configure(PTTConfig(method: pttMethod.usesPort ? pttMethod : PTTMethod.none))
            pttKeyed = false
            return
        }
        if let err = ptt.configure(pttConfig) { addError("PTT: \(err)") }
    }

    /// Включить/выключить передачу; false — PTT включить не удалось.
    @discardableResult
    private func keyPTT(_ on: Bool) -> Bool {
        let err = on ? ptt.key(true) : ptt.unkeySafe()
        pttKeyed = on && err == nil
        if let e = err { addError(e) }
        return err == nil
    }

    /// «Тест PTT»: включить передачу на 1 секунду без сигнала.
    func testPTT() {
        guard !transmitting else { return }
        guard pttMethod.usesPort else { addInfo("PTT не управляется (VOX / внешний PTT): проверять нечего"); return }
        reopenPTT()
        guard keyPTT(true) else { return }
        addInfo("Тест PTT: \(pttMethod.title), \(pttPort) — 1 с (лучше на эквивалент нагрузки)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, !self.transmitting else { return }
            self.keyPTT(false)
        }
    }

    // MARK: внешнее устройство

    /// Включить выход на `seconds` секунд (1…60). Ручное включение таймером не перебивается.
    func extPulse(_ seconds: Double? = nil) {
        guard !extManual else { return }
        guard extSet(true) else { return }
        extTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, !self.extManual else { return }
            self.extSet(false)
        }
        extTimer = w
        let sec = min(60, max(1, seconds ?? extSeconds))
        DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: w)
    }

    /// Кнопка на панели: принудительно включить / выключить выход.
    func extToggle() {
        extTimer?.cancel()
        if extOn {
            extManual = false
            extSet(false)
        } else if extSet(true) {
            extManual = true
        }
    }

    /// Порт внешнего устройства совпадает с портом PTT/CAT — так нельзя.
    var extPortConflict: Bool { !extPort.isEmpty && pttMethod.usesPort && extPort == pttPort }

    @discardableResult
    private func extSet(_ on: Bool) -> Bool {
        if on && extPortConflict {
            addError("Внешнее устройство: порт \(extPort) занят PTT/CAT — выберите другой COM-порт")
            return false
        }
        if let e = ext.set(on, port: extPort, line: extLine, invert: extInvert) {
            addError(e)
            extOn = false
            return false
        }
        extOn = on
        return true
    }

    private func extReset() {
        extTimer?.cancel()
        extManual = false
        if extOn { ext.close(line: extLine, invert: extInvert) }
        extOn = false
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
        ringer.start(style: ringStyle, devices: monitorDeviceIDs, volume: ringVolume, seconds: 4)
    }

    /// Прослушать сигнал ответа (на устройствах самоконтроля, не в эфир).
    func testAnswer() {
        ringer.start(style: answerStyle, devices: monitorDeviceIDs, volume: ringVolume, seconds: 4, once: true)
    }

    // MARK: приём

    func toggleRx() { receiving ? stopRx() : startRx() }

    func startRx() {
        AudioIO.requestMicAccess { [weak self] ok in
            guard let self = self else { return }
            guard ok else { self.addError(AudioIOError.noPermission.localizedDescription); return }
            do {
                if let warn = try self.audio.startRx(device: self.inputDevice) { self.addError(warn) }
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
        let y = muted ? [Float](repeating: 0, count: x.count) : x
        dsp.async {
            self.receiver.append(y)
        }
        if monitorRX { monitor.feedRX(y) }
        let ch = audio.activeChannel, nch = audio.inputChannels
        DispatchQueue.main.async {
            // пиковый индикатор: мгновенный подъём, плавный спад
            self.level = max(peak, self.level * 0.8)
            if self.activeChannel != ch { self.activeChannel = ch }
            if self.inputChannels != nch { self.inputChannels = nch }
        }
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
                ringer.start(style: ringStyle, devices: monitorDeviceIDs, volume: ringVolume, seconds: ringSeconds)
            }
            if extEnabled && !extPort.isEmpty { extPulse() }
            if ringOnAir {
                // небольшая пауза: вызывающая станция успевает перейти на приём
                let from = c.from
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.sendRingOnAir(to: from) }
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

    private func ensureTx() -> Bool {
        do {
            if !txReady {
                try audio.prepareTx(device: outputDevice)
                txReady = true
            }
            return true
        } catch {
            addError("Не удалось открыть выход: \(error.localizedDescription)")
            return false
        }
    }

    /// Ответ в эфир: сигнал ответа (выбирается отдельно от звонка) звучит один раз —
    /// мелодия целиком (~2,9 с) или тоны 2,5 с; передача = задержка PTT + сигнал + хвост.
    func sendRingOnAir(to: String) {
        guard ensureTx() else { return }
        let rate = audio.outputRate
        let y = [Float](repeating: 0, count: Int(pttDelay * rate))
            + Ringer.answer(answerStyle, fs: rate, volume: txLevel)
            + [Float](repeating: 0, count: Int(pttTail * rate))
        let entry = LogEntry(date: Date(), kind: .tx, from: Selcall.digitsOnly(myID), to: Selcall.digitsOnly(to),
                             title: "Ответ в эфир", text: "",
                             detail: String(format: "%.1f с · %@", Double(y.count) / rate, answerStyle.title), ok: true)
        txQueue.append((y, entry))
        if !transmitting { playNext() }
    }

    private func send(to: String, message: String?, eos: Int, title: String) {
        guard validIDs(to) else { return }
        guard ensureTx() else { return }
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
        guard keyPTT(true) else {
            addError("PTT не включился — передача отменена")
            txQueue.removeAll()
            finishTx()
            return
        }
        if monitorTX && monitor.isActive {
            monitor.feedTX(Resampler.resample(item.samples, from: audio.outputRate, to: Monitor.rate))
        }
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
        monitor.stopTX()
        txReady = false
        finishTx()
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
