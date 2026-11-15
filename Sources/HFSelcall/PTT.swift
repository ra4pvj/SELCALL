// Управление трансивером на передачу (PTT): VOX (только задержка) или линии RTS/DTR
// последовательного порта (USB-COM интерфейсы: Digirig, SignaLink с PTT-кабелем, CT-17 и т.п.).

import Darwin
import Foundation

enum PTTMode: String, CaseIterable, Identifiable {
    case vox, rts, dtr, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .vox: return "VOX (без управления)"
        case .rts: return "COM-порт, RTS"
        case .dtr: return "COM-порт, DTR"
        case .both: return "COM-порт, RTS + DTR"
        }
    }
    var usesPort: Bool { self != .vox }
    var lines: Int32 {
        switch self {
        case .vox: return 0
        case .rts: return SerialPTT.lineRTS
        case .dtr: return SerialPTT.lineDTR
        case .both: return SerialPTT.lineRTS | SerialPTT.lineDTR
        }
    }
}

enum PTTError: LocalizedError {
    case noPort, open(String, Int32), ioctl(Int32)
    var errorDescription: String? {
        switch self {
        case .noPort: return "не выбран COM-порт для PTT"
        case .open(let p, let e): return "не удалось открыть \(p): \(String(cString: strerror(e)))"
        case .ioctl(let e): return "ошибка управления линией порта: \(String(cString: strerror(e)))"
        }
    }
}

final class SerialPTT {
    // Значения из <sys/ttycom.h>: _IOW('t', 108/107, int) и TIOCM_*.
    static let tiocmbis: UInt = 0x8004_746C
    static let tiocmbic: UInt = 0x8004_746B
    static let lineDTR: Int32 = 0x002
    static let lineRTS: Int32 = 0x004

    private var fd: Int32 = -1
    private(set) var path = ""
    private(set) var keyed = false

    /// Последовательные порты (/dev/cu.*), кроме Bluetooth-заглушек.
    static func ports() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth-Incoming") && $0 != "cu.debug-console" }
            .sorted()
            .map { "/dev/" + $0 }
    }

    var isOpen: Bool { fd >= 0 }

    func open(_ p: String) throws {
        if fd >= 0 && p == path { return }
        close()
        guard !p.isEmpty else { throw PTTError.noPort }
        let f = Darwin.open(p, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { throw PTTError.open(p, errno) }
        fd = f
        path = p
        // многие USB-COM адаптеры поднимают RTS/DTR при открытии — сразу снимаем
        var both = SerialPTT.lineRTS | SerialPTT.lineDTR
        _ = withUnsafeMutablePointer(to: &both) { ioctl(fd, SerialPTT.tiocmbic, $0) }
        keyed = false
    }

    func set(_ on: Bool, lines: Int32) throws {
        guard fd >= 0 else { throw PTTError.noPort }
        var bits = lines
        let r = withUnsafeMutablePointer(to: &bits) { ioctl(fd, on ? SerialPTT.tiocmbis : SerialPTT.tiocmbic, $0) }
        guard r == 0 else { throw PTTError.ioctl(errno) }
        keyed = on
    }

    /// Снять PTT, не бросая ошибок (выход, аварийная остановка).
    func release() {
        guard fd >= 0 else { return }
        var both = SerialPTT.lineRTS | SerialPTT.lineDTR
        _ = withUnsafeMutablePointer(to: &both) { ioctl(fd, SerialPTT.tiocmbic, $0) }
        keyed = false
    }

    func close() {
        release()
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        path = ""
    }

    deinit { close() }
}
