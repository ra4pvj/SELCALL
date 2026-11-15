// HF Selcall (CCIR 493-4, CODAN/Barrett-compatible): кодер и декодер.
// Перенос python/selcall.py. Поддерживаются Selcall и Message call.
//
// FSK 100 бод, сдвиг 170 Гц, центр 1785 Гц (1870 = "1", 1700 = "0" в USB).
// Символ 10 бит: 7 инф. (LSB первым) + 3 проверочных (число нулей, MSB первым).
// Кадр (по реальной записи SELCALL_from_1111_to_1234.wav):
//   DX: 125 x6   | F     A.. C S.. [MSG..] EOS EOS EOS
//   RX: 109..104 | F F F A.. C S.. [MSG..] EOS
// RX-копия отстаёт от DX на 5 символов, символа ECC нет.
// Декодер понимает и этот кадр, и вариант M.493 (8 RX фазировки, F F, ECC).

import Foundation

public enum Selcall {
    public static let baud = 100.0
    public static let defaultCenter = 1785.0
    public static let shift = 170.0

    public static let fmtSelcall = 120
    public static let catRoutine = 100
    public static let eosAckRQ = 117
    public static let eosAckBQ = 122
    public static let eosEOS = 127
    public static let eosSet: Set<Int> = [117, 122, 127]

    static let phaseDX = 125
    static let phaseRX = [109, 108, 107, 106, 105, 104]   // как в записи CODAN
    public static let maxMessage = 64

    public static func eosName(_ v: Int) -> String {
        switch v {
        case eosAckRQ: return "ACK-RQ"
        case eosAckBQ: return "ACK-BQ"
        case eosEOS: return "EOS"
        default: return String(v)
        }
    }

    // MARK: символы

    static func symBits(_ v: Int) -> [UInt8] {
        var bits = [UInt8]()
        bits.reserveCapacity(10)
        var ones = 0
        for i in 0..<7 {
            let b = (v >> i) & 1
            ones += b
            bits.append(UInt8(b))
        }
        let zeros = 7 - ones
        bits.append(UInt8((zeros >> 2) & 1))
        bits.append(UInt8((zeros >> 1) & 1))
        bits.append(UInt8(zeros & 1))
        return bits
    }

    /// 10-битное слово (первый переданный бит = младший разряд) -> символ или -1
    static let symLUT: [Int16] = {
        var lut = [Int16](repeating: -1, count: 1024)
        for v in 0..<128 {
            var w = 0
            for (i, b) in symBits(v).enumerated() { w |= Int(b) << i }
            lut[w] = Int16(v)
        }
        return lut
    }()

    public static func digitsOnly(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.map { Character($0) })
    }

    static func idToSyms(_ ident: String) -> [Int] {
        var d = Array(digitsOnly(ident).utf8).map { Int($0) - 48 }
        if d.count % 2 == 1 { d.insert(0, at: 0) }
        var out = [Int]()
        var i = 0
        while i + 1 < d.count {
            out.append(d[i] * 10 + d[i + 1])
            i += 2
        }
        return out
    }

    static func symsToId(_ syms: [Int]) -> String {
        syms.map { String(format: "%02d", $0) }.joined()
    }

    // ВНИМАНИЕ: раскладка текста в CODAN Message call официально не опубликована.
    // Гипотеза: один символ текста = один 7-битный символ ASCII между self-ID и EOS.
    // Проверить/исправить по реальной записи с рации CODAN (здесь и в symsToMessage).
    static func messageToSyms(_ text: String) -> [Int] {
        var out = [Int]()
        for u in text.unicodeScalars {
            if out.count >= maxMessage { break }
            let v = Int(u.value)
            out.append((32...126).contains(v) ? v : 63) // '?'
        }
        return out
    }

    static func symsToMessage(_ syms: [Int?]) -> String {
        var s = ""
        for v in syms {
            if let v = v, (32...126).contains(v), let u = Unicode.Scalar(v) {
                s.unicodeScalars.append(u)
            } else {
                s += "\u{FFFD}"
            }
        }
        return s
    }

    // MARK: кодер

    /// Поток символов в порядке передачи (DX, RX, DX, RX, ...).
    public static func buildCall(to: String, from: String, message: String? = nil,
                                 format: Int = fmtSelcall, category: Int = catRoutine,
                                 eos: Int = eosAckRQ) -> [Int] {
        var toD = digitsOnly(to), frD = digitsOnly(from)
        let n = max(toD.count, frD.count)
        toD = String(repeating: "0", count: n - toD.count) + toD
        frD = String(repeating: "0", count: n - frD.count) + frD
        let a = idToSyms(toD), s = idToSyms(frD)
        let m = (message?.isEmpty == false) ? messageToSyms(message!) : []
        let rest = a + [category] + s + m
        let dx = [Int](repeating: phaseDX, count: 6) + [format] + rest + [eos, eos, eos]
        let rx = phaseRX + [format, format, format] + rest + [eos]
        var stream = [Int]()
        stream.reserveCapacity(dx.count * 2)
        for i in 0..<dx.count {
            stream.append(dx[i])
            stream.append(rx[i])
        }
        return stream
    }

    /// Длительность вызова в секундах (без учёта модуляции).
    public static func duration(of stream: [Int], dotSeconds: Double) -> Double {
        Double(Int(dotSeconds * baud) / 2 * 2 + stream.count * 10) / baud
    }

    public static func modulate(_ stream: [Int], sampleRate fs: Double, dotSeconds: Double = 6.0,
                                center: Double = defaultCenter, amplitude: Double = 0.5) -> [Float] {
        let ndots = Int(dotSeconds * baud) / 2 * 2
        var bits = [UInt8]()
        bits.reserveCapacity(ndots + stream.count * 10)
        for i in 0..<ndots { bits.append(i % 2 == 0 ? 1 : 0) }
        for v in stream { bits += symBits(v) }
        let n = Int((Double(bits.count) * fs / baud).rounded())
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        let f1 = center + shift / 2, f0 = center - shift / 2
        let ramp = max(1, Int(0.005 * fs))
        var phase = 0.0
        for t in 0..<n {
            let bi = min(Int(Double(t) * baud / fs), bits.count - 1)
            phase += 2 * Double.pi * (bits[bi] == 1 ? f1 : f0) / fs
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            var a = amplitude
            if t < ramp { a *= Double(t) / Double(ramp) }
            else if t >= n - ramp { a *= Double(n - 1 - t) / Double(ramp) }
            out[t] = Float(a * sin(phase))
        }
        return out
    }

    // MARK: демодулятор

    /// |Y(верхний)| - |Y(нижний)| со скользящим окном длиной в бит (как numpy convolve mode="same").
    static func toneDiff(_ x: [Float], fs: Double, center: Double) -> [Float] {
        let n = x.count
        let L = max(1, Int((fs / baud).rounded()))
        func mag(_ f: Double) -> [Double] {
            var pr = [Double](repeating: 0, count: n + 1)
            var pi = [Double](repeating: 0, count: n + 1)
            let w = 2 * Double.pi * f / fs
            let cw = cos(w), sw = sin(w)
            var c = 1.0, s = 0.0
            for i in 0..<n {
                let v = Double(x[i])
                pr[i + 1] = pr[i] + v * c
                pi[i + 1] = pi[i] - v * s
                let nc = c * cw - s * sw
                s = s * cw + c * sw
                c = nc
                if i & 1023 == 0 { let r = (c * c + s * s).squareRoot(); c /= r; s /= r }
            }
            var out = [Double](repeating: 0, count: n)
            for k in 0..<n {
                let lo = max(0, k - L / 2), hi = min(n, k - L / 2 + L)
                if hi <= lo { continue }
                let re = pr[hi] - pr[lo], im = pi[hi] - pi[lo]
                out[k] = (re * re + im * im).squareRoot() / Double(L)
            }
            return out
        }
        let m1 = mag(center + shift / 2), m0 = mag(center - shift / 2)
        var d = [Float](repeating: 0, count: n)
        for i in 0..<n { d[i] = Float(m1[i] - m0[i]) }
        return d
    }

    struct Found {
        var pos: Int
        var score: Int
        var call: DecodedCall
    }

    /// Ищем фазировку. Якорь q — позиция (в битах) символа RX0 = 104.
    /// Счёт: RX-фазировка 104+i в q-20i и DX 125 в q-10-20m. Подходит и для
    /// короткой (6 RX, CODAN), и для полной (8 RX, M.493) фазировки.
    static func findCalls(bits: [UInt8]) -> [Found] {
        let N = bits.count
        guard N >= 200 else { return [] }
        let M = N - 9
        var sym = [Int16](repeating: -1, count: M)
        for n in 0..<M {
            var w = 0
            for i in 0..<10 { w |= Int(bits[n + i]) << i }
            sym[n] = symLUT[w]
        }
        func at(_ j: Int) -> Int { j >= 0 && j < M ? Int(sym[j]) : -1 }
        var cands = [(pos: Int, score: Int)]()
        for q in 0..<M {
            var sc = 0
            for i in 0..<8 {
                if at(q - 20 * i) == 104 + i { sc += 1 }
                if at(q - 10 - 20 * i) == phaseDX { sc += 1 }
            }
            if sc >= 7 { cands.append((q, sc)) }
        }
        cands.sort { $0.score != $1.score ? $0.score > $1.score : $0.pos < $1.pos }
        var taken = [Int]()
        var out = [Found]()
        for c in cands where taken.allSatisfy({ abs($0 - c.pos) > 200 }) {
            taken.append(c.pos)
            if var call = extract(sym, c.pos) {
                call.endBit += c.pos
                out.append(Found(pos: c.pos, score: c.score, call: call))   // pos — якорь RX0 (точная метка)
            }
        }
        return out
    }

    struct Item {
        var value: Int?
        var conflict: Bool
        var copies: Int
    }

    /// Логическая последовательность L[k]: DX в q+10+20k и его RX-копия в q+60+20k.
    static func extract(_ sym: [Int16], _ q: Int, maxLen: Int = 90) -> DecodedCall? {
        let M = sym.count
        func at(_ j: Int) -> Int? {
            guard j >= 0, j < M else { return nil }
            let v = Int(sym[j])
            return v >= 0 ? v : nil
        }
        var L = [Item]()
        for k in -2..<maxLen {
            var d = at(q + 10 + 20 * k), r = at(q + 60 + 20 * k)
            if d == phaseDX { d = nil }
            if let rv = r, (104...111).contains(rv) { r = nil }
            switch (d, r) {
            case (nil, nil): L.append(Item(value: nil, conflict: false, copies: 0))
            case (let dv?, nil): L.append(Item(value: dv, conflict: false, copies: 1))
            case (nil, let rv?): L.append(Item(value: rv, conflict: false, copies: 1))
            case (let dv?, let rv?): L.append(Item(value: dv, conflict: dv != rv, copies: dv == rv ? 2 : 1))
            }
            if k > 6, L.suffix(3).allSatisfy({ $0.value == nil }) { break }
        }
        return parse(L)
    }

    static func parse(_ L: [Item]) -> DecodedCall? {
        let vals = L.map { $0.value }
        var i = 0
        while i < vals.count, i < 3, vals[i] == nil { i += 1 }
        guard i < vals.count, let fmt = vals[i], fmt >= 100, !eosSet.contains(fmt) else { return nil }
        i += 1
        while i < vals.count, vals[i] == fmt { i += 1 }
        var addr = [Int]()
        while i < vals.count, let v = vals[i], v < 100, addr.count < 5 {
            addr.append(v)
            i += 1
        }
        guard !addr.isEmpty, i < vals.count, let category = vals[i], category >= 100 else { return nil }
        i += 1
        guard i + addr.count <= vals.count else { return nil }
        var selfID = [Int]()
        for k in i..<(i + addr.count) {
            guard let v = vals[k], v < 100 else { return nil }
            selfID.append(v)
        }
        i += addr.count
        let head = [fmt] + addr + [category] + selfID
        var best: (j: Int, status: String, complete: Bool)? = nil
        let upper = min(vals.count, i + maxMessage + 1)
        if upper > i {
            for j in i..<upper {
                guard let e = vals[j], eosSet.contains(e) else { continue }
                let msg = vals[i..<j]
                let nxt: Int? = j + 1 < vals.count ? vals[j + 1] : nil
                var status = "BAD"
                if msg.allSatisfy({ $0 != nil }) {
                    let ecc = (head + msg.map { $0! } + [e]).reduce(0, ^)
                    if nxt == ecc { status = "ok" } else if nxt == nil || nxt == e { status = "нет" }
                }
                if status != "BAD" { best = (j, status, nxt != nil); break }
                if best == nil { best = (j, status, nxt != nil) }
            }
        }
        guard let b = best, let eos = vals[b.j] else { return nil }
        let msgSyms = Array(vals[i..<b.j])
        let seg = L.prefix(b.j + 1)
        let conflicts = seg.filter { $0.conflict }.count
        let valid = b.status == "ok" ||
            (b.status == "нет" && conflicts == 0 && !msgSyms.contains(where: { $0 == nil }))
        var call = DecodedCall(time: 0, format: fmt, to: symsToId(addr), from: symsToId(selfID),
                               category: category,
                               message: msgSyms.isEmpty ? "" : symsToMessage(msgSyms),
                               eos: eos, ecc: b.status, eccOK: valid, conflicts: conflicts,
                               center: 0, inverted: false, phasingScore: 0)
        call.complete = b.complete
        call.endBit = 70 + 20 * (b.j - 2)        // относительно якоря q; extract/findCalls добавят q
        return call
    }

    /// Декодирование на одном центре. `x` — моно, любая fs (быстрее всего 8000).
    static func decodeAt(_ x: [Float], fs: Double, center: Double) -> [DecodedCall] {
        let d = toneDiff(x, fs: fs, center: center)
        let spb = fs / baud
        var found = [DecodedCall]()
        for k in 0..<8 {
            let ph = Double(k) * spb / 8
            let count = Int((Double(d.count) - ph) / spb)
            guard count >= 200 else { continue }
            var idx = [Int](repeating: 0, count: count)
            var raw = [UInt8](repeating: 0, count: count)
            for j in 0..<count {
                let ix = min(d.count - 1, Int(ph + Double(j) * spb))
                idx[j] = ix
                raw[j] = d[ix] > 0 ? 1 : 0
            }
            for inv in [false, true] {
                let bits = inv ? raw.map { 1 - $0 } : raw
                for f in findCalls(bits: bits) {
                    var c = f.call
                    // время начала фазировки = якорь − 2,3 с; без обрезки по краю окна,
                    // иначе при сдвиге окна время «плыло» и вызов выдавался повторно
                    c.time = Double(idx[f.pos]) / fs - 2.3
                    c.endTime = Double(idx[min(idx.count - 1, max(0, c.endBit))]) / fs
                    c.center = center
                    c.inverted = inv
                    c.phasingScore = f.score
                    found.append(c)
                }
            }
        }
        return found
    }

    /// Объединение дублей (разные центры / фазы / полярности).
    static func merge(_ found: [DecodedCall]) -> [DecodedCall] {
        let sorted = found.sorted { a, b in
            if a.eccOK != b.eccOK { return a.eccOK }
            if a.conflicts != b.conflicts { return a.conflicts < b.conflicts }
            return a.phasingScore > b.phasingScore
        }
        var out = [DecodedCall]()
        for c in sorted where out.allSatisfy({ abs($0.time - c.time) > 0.3 }) {
            out.append(c)
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Пакетное декодирование: АПЧ + все центры. Сигнал в fs (рекомендуется 8000).
    public static func decode(_ x: [Float], fs: Double, center: Double? = nil) -> [DecodedCall] {
        var centers: [Double]
        if let c = center {
            centers = [c]
        } else {
            let afc = AFC(sampleRate: fs)
            afc.append(x)
            centers = afc.topCenters(3)
        }
        var found = [DecodedCall]()
        for c in centers { found += decodeAt(x, fs: fs, center: c) }
        return merge(found)
    }
}

public struct DecodedCall: Identifiable, Equatable {
    public let id = UUID()
    public var time: Double          // секунды от начала анализируемого буфера/файла
    public var format: Int
    public var to: String
    public var from: String
    public var category: Int
    public var message: String
    public var eos: Int
    /// "ok" — ECC совпал, "нет" — символа ECC нет (кадр CODAN), "BAD" — ошибка.
    public var ecc: String
    /// Вызов принят надёжно: ECC ok, либо ECC нет и все копии DX/RX согласованы.
    public var eccOK: Bool
    public var conflicts: Int
    public var center: Double
    public var inverted: Bool
    public var phasingScore: Int
    /// После EOS виден следующий символ (повтор EOS или ECC) — кадр точно закончен.
    public var complete: Bool = true
    /// Время конца кадра (с), в той же шкале, что и `time`.
    public var endTime: Double = 0
    var endBit: Int = 0

    public var isMessage: Bool { !message.isEmpty }
    public var eosName: String { Selcall.eosName(eos) }

    public var summary: String {
        var s = String(format: "[%7.2fs] %@ %@ -> %@", time, isMessage ? "MESSAGE" : "SELCALL", from, to)
        if isMessage { s += "  \"\(message)\"" }
        s += String(format: "  fmt=%d cat=%d %@ ECC:%@ %@  f0=%.1fHz %@", format, category, eosName,
                    ecc, eccOK ? "OK" : "СОМНИТЕЛЬНО", center, inverted ? "inverted" : "normal")
        if conflicts > 0 { s += " conflicts=\(conflicts)" }
        return s
    }
}
