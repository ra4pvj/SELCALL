// WAV ввод/вывод, передискретизация, транслитерация.

import Foundation

public enum WAV {
    public enum WAVError: Error, CustomStringConvertible {
        case notWAV, unsupported(String), noData
        public var description: String {
            switch self {
            case .notWAV: return "не WAV (RIFF/WAVE) файл"
            case .unsupported(let s): return "неподдерживаемый формат: \(s)"
            case .noData: return "нет блока data"
            }
        }
    }

    /// Возвращает первый канал и частоту дискретизации.
    public static func read(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let d = try Data(contentsOf: url)
        let b = [UInt8](d)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard b.count >= 12, b[0...3] == [82, 73, 70, 70], b[8...11] == [87, 65, 86, 69] else { throw WAVError.notWAV }
        var o = 12
        var fmtTag = 0, ch = 1, rate = 0, bits = 0
        var dataRange: Range<Int>?
        while o + 8 <= b.count {
            let id = String(bytes: b[o..<o + 4], encoding: .ascii) ?? ""
            let size = u32(o + 4)
            let start = o + 8
            let end = min(b.count, start + size)
            if id == "fmt " {
                fmtTag = u16(start); ch = u16(start + 2); rate = u32(start + 4); bits = u16(start + 14)
                if fmtTag == 0xFFFE && size >= 26 { fmtTag = u16(start + 24) } // WAVE_FORMAT_EXTENSIBLE
            } else if id == "data" {
                dataRange = start..<end
            }
            o = start + size + (size & 1)
        }
        guard let r = dataRange else { throw WAVError.noData }
        guard ch >= 1, rate > 0 else { throw WAVError.unsupported("fmt") }
        let bps = bits / 8
        let frame = bps * ch
        guard frame > 0 else { throw WAVError.unsupported("bits=\(bits)") }
        let n = r.count / frame
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = r.lowerBound + i * frame
            switch (fmtTag, bits) {
            case (1, 8): out[i] = (Float(b[p]) - 128) / 128
            case (1, 16): out[i] = Float(Int16(bitPattern: UInt16(u16(p)))) / 32768
            case (1, 24):
                var v = Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16
                if v & 0x800000 != 0 { v -= 0x1000000 }
                out[i] = Float(v) / 8_388_608
            case (1, 32): out[i] = Float(Int32(bitPattern: UInt32(u32(p)))) / 2_147_483_648
            case (3, 32): out[i] = Float(bitPattern: UInt32(u32(p)))
            default: throw WAVError.unsupported("tag=\(fmtTag) bits=\(bits)")
            }
        }
        return (out, Double(rate))
    }

    /// Пишет 16-бит моно PCM.
    public static func write(_ url: URL, samples: [Float], sampleRate: Int) throws {
        var d = Data()
        func put32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func put16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let dataBytes = samples.count * 2
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put32(16)
        put16(1); put16(1); put32(sampleRate); put32(sampleRate * 2); put16(2); put16(16)
        d.append(contentsOf: Array("data".utf8)); put32(dataBytes)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices { pcm[i] = Int16(max(-1, min(1, samples[i])) * 32767).littleEndian }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: url)
    }
}

public enum Resampler {
    /// Передискретизация оконным sinc (Блэкман). Для понижения частоты
    /// одновременно фильтрует выше min(fsIn, fsOut)/2 * 0.85.
    public static func resample(_ x: [Float], from fsIn: Double, to fsOut: Double) -> [Float] {
        if abs(fsIn - fsOut) < 0.5 || x.isEmpty { return x }
        let ratio = fsIn / fsOut
        let cutoff = 0.85 * min(fsIn, fsOut) / 2          // Гц
        let fc = cutoff / fsIn                              // доля fsIn
        let half = Int((16.0 * max(1, ratio)).rounded(.up)) // полуширина ядра в отсчётах входа
        let nOut = Int(Double(x.count) / ratio)
        var out = [Float](repeating: 0, count: nOut)
        x.withUnsafeBufferPointer { px in
            for m in 0..<nOut {
                let p = Double(m) * ratio
                let i0 = Int(p.rounded(.down))
                var acc = 0.0, wsum = 0.0
                let lo = max(0, i0 - half + 1), hi = min(x.count - 1, i0 + half)
                if lo > hi { continue }
                for i in lo...hi {
                    let t = Double(i) - p
                    let a = 2 * fc * t
                    let sinc = abs(a) < 1e-9 ? 1.0 : sin(Double.pi * a) / (Double.pi * a)
                    let u = (t + Double(half)) / Double(2 * half)   // 0..1
                    let w = 0.42 - 0.5 * cos(2 * Double.pi * u) + 0.08 * cos(4 * Double.pi * u)
                    let h = sinc * w
                    acc += Double(px[i]) * h
                    wsum += h
                }
                out[m] = Float(wsum != 0 ? acc / wsum : 0)
            }
        }
        return out
    }
}

public enum Translit {
    static let table: [Character: String] = [
        "А": "A", "Б": "B", "В": "V", "Г": "G", "Д": "D", "Е": "E", "Ё": "E", "Ж": "ZH", "З": "Z",
        "И": "I", "Й": "J", "К": "K", "Л": "L", "М": "M", "Н": "N", "О": "O", "П": "P", "Р": "R",
        "С": "S", "Т": "T", "У": "U", "Ф": "F", "Х": "H", "Ц": "C", "Ч": "CH", "Ш": "SH", "Щ": "SCH",
        "Ъ": "", "Ы": "Y", "Ь": "", "Э": "E", "Ю": "YU", "Я": "YA",
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z",
        "и": "i", "й": "j", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "c", "ч": "ch", "ш": "sh", "щ": "sch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya", "№": "N",
    ]

    public static func latin(_ s: String) -> String {
        var out = ""
        for ch in s { out += table[ch] ?? String(ch) }
        return out
    }
}
