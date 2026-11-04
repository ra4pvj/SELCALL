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
        }
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
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            LogView()
            Divider()
            composer
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(m) }
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
            LevelMeter(level: m.level).frame(width: 90, height: 10)
            Text(afcText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Button(m.receiving ? "Стоп приём" : "Приём") { m.toggleRx() }
                .tint(m.receiving ? .red : .accentColor)
                .buttonStyle(.borderedProminent)
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
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

struct LevelMeter: View {
    var level: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(level > 0.9 ? Color.red : (level > 0.6 ? Color.orange : Color.green))
                    .frame(width: g.size.width * CGFloat(min(1, level)))
            }
        }
        .help(String(format: "Уровень входа: %.0f%%", level * 100))
    }
}

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) private var dismiss

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
                    Toggle("Автоматически подтверждать вызовы на мой ID (ACK)", isOn: $m.autoAck)
                }
                Section("Приём") {
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
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
    }
}
