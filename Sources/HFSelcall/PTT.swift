// Управление передачей: PTT по линиям RTS/DTR или CAT-командой (ICOM CI-V, YAESU, YAESU-OLD,
// KENWOOD, ELECRAFT). Перенос hfpager_ptt.py из проекта HFP (ra4pvj/HFP) на Swift.
// Команды составлены по открытым CAT-описаниям производителей, на реальных трансиверах
// не проверялись — сначала «Тест PTT» на эквиваленте нагрузки.

import Darwin
import Foundation

enum PTTMethod: String, CaseIterable, Identifiable {
    case none = "none", rts = "RTS", dtr = "DTR", rtsDtr = "RTS+DTR"
    case icom = "ICOM", yaesu = "YAESU", yaesuOld = "YAESU-OLD", kenwood = "KENWOOD", elecraft = "ELECRAFT"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "нет (VOX / внешний PTT)"
        case .rts: return "RTS"
        case .dtr: return "DTR"
        case .rtsDtr: return "RTS + DTR"
        case .icom: return "ICOM (CI-V)"
        case .yaesu: return "YAESU (TX1; / TX0;)"
        case .yaesuOld: return "YAESU-OLD (FT-817/857/897)"
        case .kenwood: return "KENWOOD (TX; / RX;)"
        case .elecraft: return "ELECRAFT (TX; / RX;)"
        }
    }
    var isLine: Bool { self == .rts || self == .dtr || self == .rtsDtr }
    var usesPort: Bool { self != .none }
    var defaultBaud: Int {
        switch self {
        case .icom: return 19200
        case .yaesu, .elecraft: return 38400
        default: return 9600
        }
    }
}

enum PTTCat {
    static let bauds = [1200, 4800, 9600, 19200, 38400, 57600, 115200]
    static let kenwoodVariants = ["TX;", "TX0;", "TX1;"]
    /// Адреса CI-V по умолчанию (можно поменять в меню радио — поэтому есть ручной ввод).
    static let icomModels: [(name: String, addr: UInt8?)] = [
        ("IC-7300", 0x94), ("IC-7300MK2", 0xB6), ("IC-705", 0xA4), ("IC-7610", 0x98), ("IC-9700", 0xA2),
        ("IC-7100", 0x88), ("IC-7851/7800", 0x8E), ("IC-7700", 0x74), ("IC-7600", 0x7A), ("IC-7410", 0x80),
        ("IC-7200", 0x76), ("IC-7000", 0x70), ("IC-756PRO3", 0x6E), ("IC-756PRO2", 0x64), ("IC-756PRO", 0x5C),
        ("IC-746PRO", 0x66), ("IC-746", 0x56), ("IC-706MKIIG", 0x58), ("IC-718", 0x5E), ("IC-703", 0x68),
        ("IC-707", 0x3E), ("IC-775", 0x46), ("IC-781", 0x26), ("Custom", nil),
    ]

    static func parseHexAddr(_ text: String) -> UInt8? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        t = t.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "h", with: "")
        guard let v = UInt8(t, radix: 16), v > 0, v < 0xFE else { return nil }
        return v
    }

    /// Байты CAT-команды, nil для методов с линиями порта.
    static func command(_ m: PTTMethod, on: Bool, icomAddr: UInt8 = 0x94, kenwood: String = "TX;") -> [UInt8]? {
        switch m {
        case .icom: return [0xFE, 0xFE, icomAddr, 0xE0, 0x1C, 0x00, on ? 0x01 : 0x00, 0xFD]
        case .yaesu: return Array((on ? "TX1;" : "TX0;").utf8)
        case .yaesuOld: return [0, 0, 0, 0, on ? 0x08 : 0x88]
        case .kenwood, .elecraft:
            if !on { return Array("RX;".utf8) }
            return Array((kenwoodVariants.contains(kenwood) ? kenwood : "TX;").utf8)
        default: return nil
        }
    }
}

struct PTTConfig: Equatable {
    var method: PTTMethod = .none
    var port = ""
    var baud = 9600
    var invert = false
    var icomAddr: UInt8 = 0x94
    var kenwood = "TX;"
}

enum PTTError: LocalizedError {
    case noPort, open(String, Int32), io(String, Int32), notOpen
    var errorDescription: String? {
        switch self {
        case .noPort: return "не выбран COM-порт для PTT/CAT"
        case .open(let p, let e): return "не удалось открыть порт \(p): \(String(cString: strerror(e)))"
        case .io(let what, let e): return "\(what): \(String(cString: strerror(e)))"
        case .notOpen: return "порт PTT не открыт"
        }
    }
}

/// Потокобезопасный PTT (вызовы сериализуются блокировкой).
final class PTTController {
    // <sys/ttycom.h>: _IOW('t', 108/107, int) и TIOCM_*
    private static let tiocmbis: UInt = 0x8004_746C
    private static let tiocmbic: UInt = 0x8004_746B
    private static let lineDTR: Int32 = 0x002
    private static let lineRTS: Int32 = 0x004

    private var fd: Int32 = -1
    private(set) var cfg = PTTConfig()
    private(set) var keyed = false
    private let lock = NSRecursiveLock()

    /// Последовательные порты (/dev/cu.*).
    static func ports() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth-Incoming") && $0 != "cu.debug-console" }
            .sorted().map { "/dev/" + $0 }
    }

    var isOpen: Bool { fd >= 0 }

    /// Применить настройки (переоткрыть порт при изменении). nil — успех, иначе текст ошибки.
    @discardableResult
    func configure(_ c: PTTConfig) -> String? {
        lock.lock(); defer { lock.unlock() }
        if keyed { _ = try? send(false) }
        if fd >= 0 && c == cfg { return nil }
        closeLocked()
        cfg = c
        guard c.method.usesPort else { return nil }
        do { try openLocked() } catch { return error.localizedDescription }
        return nil
    }

    private func setLines(_ lines: Int32, _ on: Bool) throws {
        var bits = lines
        let r = withUnsafeMutablePointer(to: &bits) { ioctl(fd, on ? Self.tiocmbis : Self.tiocmbic, $0) }
        if r != 0 { throw PTTError.io("линия порта", errno) }
    }

    /// Уровни линий в покое: для RTS/DTR с инверсией — «1», иначе «0».
    private func idleLines() throws {
        let m = cfg.method
        let inv = cfg.invert && m.isLine
        let rts = (m == .rts || m == .rtsDtr) && inv
        let dtr = (m == .dtr || m == .rtsDtr) && inv
        try setLines(Self.lineRTS, rts)
        try setLines(Self.lineDTR, dtr)
    }

    private func openLocked() throws {
        guard !cfg.port.isEmpty else { throw PTTError.noPort }
        let f = Darwin.open(cfg.port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { throw PTTError.open(cfg.port, errno) }
        fd = f
        var t = termios()
        if tcgetattr(fd, &t) == 0 {
            cfmakeraw(&t)
            cfsetspeed(&t, speed_t(cfg.baud))
            t.c_cflag |= tcflag_t(CLOCAL | CREAD)
            t.c_cflag &= ~tcflag_t(HUPCL)          // не дёргать линии при закрытии
            _ = tcsetattr(fd, TCSANOW, &t)
        }
        do { try idleLines() } catch { /* CAT-адаптеры без линий — не критично */ }
    }

    private func closeLocked() {
        if fd >= 0 {
            if keyed { _ = try? send(false) }
            _ = try? idleLines()
            Darwin.close(fd)
        }
        fd = -1
        keyed = false
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closeLocked()
    }

    private func send(_ on: Bool) throws {
        let m = cfg.method
        guard m != .none else { keyed = on; return }
        guard fd >= 0 else { throw PTTError.notOpen }
        if m.isLine {
            let level = on != cfg.invert
            if m == .rts || m == .rtsDtr { try setLines(Self.lineRTS, level) }
            if m == .dtr || m == .rtsDtr { try setLines(Self.lineDTR, level) }
        } else if let data = PTTCat.command(m, on: on, icomAddr: cfg.icomAddr, kenwood: cfg.kenwood) {
            tcflush(fd, TCIFLUSH)
            let n = data.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n != data.count { throw PTTError.io("запись CAT-команды", errno) }
            tcdrain(fd)
            if m == .icom {
                usleep(50_000)                       // радио повторяет кадр и отвечает FB — сбрасываем
                tcflush(fd, TCIFLUSH)
            }
        }
        keyed = on
    }

    /// Включить/выключить передачу. nil — успех, иначе текст ошибки.
    @discardableResult
    func key(_ on: Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        do {
            if on && cfg.method.usesPort && fd < 0 { try openLocked() }
            try send(on)
            if on && !cfg.method.isLine && cfg.method != .none { usleep(50_000) }
            return nil
        } catch {
            if !on { keyed = false }
            return "Ошибка PTT (\(cfg.method.rawValue)): \(error.localizedDescription)"
        }
    }

    /// Снять PTT любой ценой (повтор с переоткрытием порта), без исключений.
    @discardableResult
    func unkeySafe() -> String? {
        var err: String?
        for _ in 0..<2 {
            err = key(false)
            if err == nil { return nil }
            lock.lock()
            closeLocked()
            lock.unlock()
        }
        return err
    }

    deinit { close() }
}

// MARK: - Внешнее устройство (сирена, лампа, реле) — «1» на линии COM-порта при вызове

enum ExtLine: String, CaseIterable, Identifiable {
    case rts = "RTS", dtr = "DTR", both = "RTS+DTR"
    var id: String { rawValue }
    var bits: Int32 {
        switch self {
        case .rts: return 0x004
        case .dtr: return 0x002
        case .both: return 0x006
        }
    }
}

/// Управление внешним устройством линией RTS/DTR последовательного порта.
/// На macOS порт можно открыть и параллельно с PTT (тот же порт, другая линия).
final class ExtControl {
    private static let tiocmbis: UInt = 0x8004_746C
    private static let tiocmbic: UInt = 0x8004_746B
    private var fd: Int32 = -1
    private(set) var port = ""
    private(set) var isOn = false
    private let lock = NSLock()

    private func openLocked(_ p: String) throws {
        if fd >= 0 && p == port { return }
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        guard !p.isEmpty else { throw PTTError.noPort }
        let f = Darwin.open(p, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { throw PTTError.open(p, errno) }
        var t = termios()
        if tcgetattr(f, &t) == 0 {
            t.c_cflag |= tcflag_t(CLOCAL)
            t.c_cflag &= ~tcflag_t(HUPCL)
            _ = tcsetattr(f, TCSANOW, &t)
        }
        fd = f
        port = p
    }

    private func setLines(_ bits: Int32, _ high: Bool) throws {
        var b = bits
        let r = withUnsafeMutablePointer(to: &b) { ioctl(fd, high ? Self.tiocmbis : Self.tiocmbic, $0) }
        if r != 0 { throw PTTError.io("линия порта", errno) }
    }

    /// Включить/выключить выход. nil — успех, иначе текст ошибки.
    @discardableResult
    func set(_ on: Bool, port p: String, line: ExtLine, invert: Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        do {
            try openLocked(p)
            try setLines(line.bits, on != invert)
            isOn = on
            return nil
        } catch {
            return "Внешнее устройство: \(error.localizedDescription)"
        }
    }

    /// Привести линию в исходное состояние (выключено) и закрыть порт.
    func close(line: ExtLine, invert: Bool) {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 {
            _ = try? setLines(line.bits, invert)
            Darwin.close(fd)
        }
        fd = -1
        port = ""
        isOn = false
    }
}
