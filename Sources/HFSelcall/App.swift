// HF Selcall для macOS: окно журнала, панель отправки, настройки звука.

import AppKit
import CoreAudio
import SelcallCore
import SwiftUI

@main
struct HFSelcallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("HF Selcall") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть запись…") { model.openWAV() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .appSettings) { SettingsMenuButton() }
        }
        // Настройки — отдельное окно (а не лист поверх главного): открывается повторно
        // сколько угодно раз и может оставаться открытым во время работы
        Window("Настройки HF Selcall", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .windowResizability(.contentMinSize)
    }
}

struct SettingsMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Настройки…") { openWindow(id: "settings") }.keyboardShortcut(",")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // нужно при запуске бинарника вне .app-бандла
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let e = m.incoming { IncomingBanner(entry: e) }
            LogView()
            Divider()
            composer
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("Мой ID").foregroundStyle(.secondary)
                TextField("1234", text: $m.myID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .font(.system(.body, design: .monospaced))
            }
            Picker("Вход", selection: $m.inputDevice) {
                Text("По умолчанию").tag(AudioDeviceID(0))
                ForEach(m.inputDevices) { Text($0.name).tag($0.id) }
            }
            .frame(maxWidth: 240)
            Picker("Выход", selection: $m.outputDevice) {
                Text("По умолчанию").tag(AudioDeviceID(0))
                ForEach(m.outputDevices) { Text($0.name).tag($0.id) }
            }
            .frame(maxWidth: 240)
            Button { m.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                .help("Обновить список устройств")
            Spacer()
            TxLamp(on: m.transmitting, keyed: m.pttKeyed)
            LevelMeter(level: m.level)
            if m.receiving && m.inputChannels > 1 {
                Text("кан. \(m.activeChannel)").font(.caption).foregroundStyle(.secondary)
                    .help("Канал входа, по которому идёт приём (настройки → Приём → Канал входа)")
            }
            Text(afcText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Button(m.receiving ? "Стоп приём" : "Приём") { m.toggleRx() }
                .tint(m.receiving ? .red : .accentColor)
                .buttonStyle(.borderedProminent)
            Button { openWindow(id: "settings") } label: { Image(systemName: "gearshape") }
                .help("Настройки")
        }
        .padding(10)
    }

    private var afcText: String {
        if !m.autoAFC { return String(format: "f0 %.1f Гц", m.fixedCenter) }
        guard m.receiving, let c = m.centers.first else { return "АПЧ —" }
        return String(format: "АПЧ %.1f Гц", c)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Кому").foregroundStyle(.secondary)
                TextField("ID", text: $m.toID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .font(.system(.body, design: .monospaced))
                Button("Вызов") { m.sendSelcall() }
                    .help("Selcall: индивидуальный вызов")
                    .disabled(m.toID.isEmpty)
                Spacer()
                if m.transmitting {
                    Label("Передача…", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.red)
                    Button("Прервать") { m.stopTx() }
                }
                Menu("WAV") {
                    Button("Сохранить вызов в WAV…") { m.saveWAV(message: false) }
                    Button("Сохранить сообщение в WAV…") { m.saveWAV(message: true) }
                    Divider()
                    Button("Декодировать запись…") { m.openWAV() }
                }
                .fixedSize()
            }
            HStack(spacing: 8) {
                TextField("Текст сообщения (до \(Selcall.maxMessage) символов)", text: $m.messageText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { m.sendMessage() }
                Text("\(min(m.messageText.count, Selcall.maxMessage))/\(Selcall.maxMessage)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(m.messageText.count > Selcall.maxMessage ? Color.red : Color.secondary)
                Button("Отправить") { m.sendMessage() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(m.toID.isEmpty || m.messageText.isEmpty)
            }
        }
        .padding(10)
    }
}

struct LogView: View {
    @EnvironmentObject var m: AppModel

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm:ss"
        return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(m.log) { e in
                    row(e).id(e.id)
                        .contextMenu {
                            if !e.from.isEmpty {
                                Button("Ответить \(e.from)") { m.reply(to: e) }
                            }
                            Button("Копировать") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    "\(Self.df.string(from: e.date)) \(e.title) \(e.from)→\(e.to) \(e.text)",
                                    forType: .string)
                            }
                        }
                        .onTapGesture(count: 2) { m.reply(to: e) }
                }
            }
            .listStyle(.inset)
            .onChange(of: m.log.count) { _ in
                if let last = m.log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .overlay {
                if m.log.isEmpty {
                    Text("Нажмите «Приём», чтобы слушать эфир, или откройте запись (⌘O)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ e: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(e.kind))
                .foregroundStyle(color(e))
                .frame(width: 16)
            Text(Self.df.string(from: e.date))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.title).fontWeight(.semibold)
                    if !e.from.isEmpty || !e.to.isEmpty {
                        Text("\(e.from) → \(e.to)").font(.system(.body, design: .monospaced))
                    }
                }
                if !e.text.isEmpty {
                    Text(e.text).textSelection(.enabled)
                }
                if !e.detail.isEmpty {
                    Text(e.detail).font(.caption).foregroundStyle(e.ok ? Color.secondary : Color.red)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func icon(_ k: LogEntry.Kind) -> String {
        switch k {
        case .rx: return "arrow.down.circle.fill"
        case .tx: return "arrow.up.circle.fill"
        case .info: return "info.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ e: LogEntry) -> Color {
        switch e.kind {
        case .rx: return e.ok ? .green : .orange
        case .tx: return .blue
        case .info: return .secondary
        case .error: return .red
        }
    }
}

/// Пиковый индикатор входа в дБFS (−60…0), как в HFP: зелёный, жёлтый с −12 дБ, красный с −3 дБ.
struct LevelMeter: View {
    var level: Float          // пик, линейно 0…1 (1 = полная шкала)
    static let floor = -60.0
    var db: Double { level > 0 ? max(Self.floor, 20 * log10(Double(level))) : Self.floor }
    var fraction: CGFloat { CGFloat((db - Self.floor) / -Self.floor) }
    var color: Color { db > -3 ? .red : (db > -12 ? .yellow : .green) }

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3).fill(color)
                        .frame(width: g.size.width * min(1, max(0, fraction)))
                    // риски −40, −20, −12, −6, −3 дБ
                    ForEach([-40.0, -20.0, -12.0, -6.0, -3.0], id: \.self) { m in
                        Rectangle().fill(Color.primary.opacity(0.35))
                            .frame(width: 1)
                            .offset(x: g.size.width * CGFloat((m - Self.floor) / -Self.floor))
                    }
                }
            }
            .frame(width: 110, height: 10)
            Text(level > 0 && db > Self.floor ? String(format: "%5.1f дБ", db) : "  —  дБ")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(db > -3 ? Color.red : Color.secondary)
                .frame(width: 62, alignment: .trailing)
        }
        .help("Пик входа в дБ относительно полной шкалы (0 дБFS). Красный — близко к перегрузке.")
    }
}

struct SettingsView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Настройки").font(.title2).bold()
            Form {
                Section("Передача") {
                    HStack {
                        Text("Преамбула (точки)")
                        Spacer()
                        Stepper(String(format: "%.1f с", m.dotSeconds), value: $m.dotSeconds, in: 0.4...12, step: 0.2)
                    }
                    Text("Для станций в режиме сканирования ставьте не меньше времени цикла сканирования (обычно 6–12 с).")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Уровень")
                        Slider(value: $m.txLevel, in: 0.05...1.0)
                        Text(String(format: "%.0f%%", m.txLevel * 100)).monospacedDigit().frame(width: 44)
                    }
                    Toggle("Транслитерировать кириллицу в сообщениях", isOn: $m.transliterate)
                }
                Section("Управление передачей (PTT / CAT)") {
                    Picker("Метод", selection: $m.pttMethod) {
                        ForEach(PTTMethod.allCases) { Text($0.title).tag($0) }
                    }
                    if m.pttMethod.usesPort {
                        HStack {
                            Picker("Порт", selection: $m.pttPort) {
                                Text("— не выбран —").tag("")
                                ForEach(m.pttPorts, id: \.self) { Text($0).tag($0) }
                            }
                            Button { m.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                                .help("Обновить список портов")
                        }
                        Picker("Скорость", selection: $m.pttBaud) {
                            ForEach(PTTCat.bauds, id: \.self) { Text("\($0)").tag($0) }
                        }
                        if m.pttMethod.isLine {
                            Toggle("Инверсия линии", isOn: $m.pttInvert)
                        }
                        if m.pttMethod == .icom {
                            HStack {
                                Picker("Модель ICOM", selection: $m.icomModel) {
                                    ForEach(PTTCat.icomModels, id: \.name) { Text($0.name).tag($0.name) }
                                }
                                Text("CI-V")
                                TextField("94", text: $m.icomAddr)
                                    .frame(width: 50)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        if m.pttMethod == .kenwood || m.pttMethod == .elecraft {
                            Picker("Команда TX", selection: $m.kenwoodVariant) {
                                ForEach(PTTCat.kenwoodVariants, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        Button("Тест PTT (1 с)") { m.testPTT() }
                            .help("Включить передачу на 1 с без звука — лучше на эквивалент нагрузки")
                        Text("CAT-команды составлены по документации производителей и на трансиверах не проверялись.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Задержка PTT/VOX → сигнал")
                        Spacer()
                        Stepper(String(format: "%.1f с", m.pttDelay), value: $m.pttDelay, in: 0...3, step: 0.1)
                    }
                    HStack {
                        Text("Хвост после сигнала")
                        Spacer()
                        Stepper(String(format: "%.1f с", m.pttTail), value: $m.pttTail, in: 0...2, step: 0.1)
                    }
                    Toggle("Не принимать во время передачи", isOn: $m.muteRxOnTx)
                    Text(m.muteRxOnTx
                         ? "На время передачи приём глушится, свой сигнал не декодируется."
                         : "Приём работает и во время передачи; свой сигнал попадёт в журнал как «Своя передача (эхо)».")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Самоконтроль (можно несколько устройств)") {
                    Toggle("Слушать эфир (вход)", isOn: $m.monitorRX)
                    Toggle("Слушать свою передачу", isOn: $m.monitorTX)
                    HStack {
                        Text("Уровень самоконтроля")
                        Slider(value: $m.monitorLevel, in: 0...1)
                        Text(String(format: "%.0f%%", m.monitorLevel * 100)).monospacedDigit().frame(width: 44)
                    }
                    ForEach(m.outputDevices) { d in
                        Toggle(d.name, isOn: Binding(get: { m.isMonitorDevice(d) },
                                                     set: { m.setMonitorDevice(d, $0) }))
                    }
                    if m.monitorDevices.contains(where: { n in m.outputDevices.first(where: { $0.id == m.outputDevice })?.name == n }) {
                        Text("Отмечен выход на трансивер: самоконтроль и звонок уйдут в эфир!")
                            .font(.caption).foregroundStyle(.red)
                    } else {
                        Text("Например, динамики ноутбука, когда трансивер подключён к внешней звуковой карте.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Звонок при вызове на мой ID") {
                    Toggle("Звонить", isOn: $m.ringEnabled)
                    Picker("Сигнал", selection: $m.ringStyle) {
                        ForEach(RingStyle.allCases) { Text($0.title).tag($0) }
                    }
                    HStack {
                        Text("Громкость")
                        Slider(value: $m.ringVolume, in: 0.05...1.0)
                        Button("Прослушать") { m.testRing() }
                    }
                    HStack {
                        Text("Звонить не дольше")
                        Spacer()
                        Stepper(String(format: "%.0f с", m.ringSeconds), value: $m.ringSeconds, in: 5...300, step: 5)
                    }
                    Toggle("Звонок в эфир — ответ вызывающей станции (как CODAN / Vertex)", isOn: $m.ringOnAir)
                    if m.ringOnAir {
                        Text("Через 1 с после принятого вызова передатчик включается ровно на 5 с и передаёт звонок "
                             + "с уровнем передачи. На подтверждения (ACK) не отвечает.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(m.monitorDevices.isEmpty ? "Звонок звучит на системном выходе Mac."
                                                  : "Звонок звучит на устройствах самоконтроля.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Приём") {
                    Picker("Канал входа", selection: $m.inputChannel) {
                        Text("Авто (где есть сигнал)").tag(0)
                        Text("1 (левый)").tag(1)
                        Text("2 (правый)").tag(2)
                    }
                    if m.receiving && m.inputChannels > 1 {
                        Text("Сейчас используется канал \(m.activeChannel) из \(m.inputChannels).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Автоподстройка частоты (АПЧ)", isOn: $m.autoAFC)
                    HStack {
                        Text("Центр без АПЧ")
                        Spacer()
                        Stepper(String(format: "%.0f Гц", m.fixedCenter), value: $m.fixedCenter,
                                in: 1000...2600, step: 5)
                    }
                    .disabled(m.autoAFC)
                    Toggle("Показывать вызовы не на мой ID", isOn: $m.showAll)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Очистить журнал") { m.clearLog() }
                Spacer()
                Button("Готово") { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 420, idealHeight: 720)
    }
}

struct TxLamp: View {
    var on: Bool
    var keyed: Bool
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(on || keyed ? Color.red : Color.secondary.opacity(0.3))
                .frame(width: 10, height: 10)
            Text("TX").font(.caption.bold()).foregroundStyle(on || keyed ? Color.red : Color.secondary)
        }
        .help(keyed ? "PTT включён — идёт передача" : "Передача выключена")
    }
}

struct IncomingBanner: View {
    @EnvironmentObject var m: AppModel
    let entry: LogEntry
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .font(.title2)
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.title) от \(entry.from)").font(.headline)
                if !entry.text.isEmpty { Text(entry.text).lineLimit(2) }
            }
            Spacer()
            Button("Ответить") { m.answerRing() }
                .buttonStyle(.borderedProminent)
                .help("Подставить ID в поле «Кому» и выключить звонок")
            Button("Сбросить") { m.stopRing() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(10)
        .background(Color.orange.opacity(0.15))
    }
}
