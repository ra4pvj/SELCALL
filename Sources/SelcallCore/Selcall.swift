// HF Selcall (CCIR 493-4, CODAN/Barrett-compatible): кодер и декодер.
// Перенос python/selcall.py. Поддерживаются Selcall и Message call.
//
// FSK 100 бод, сдвиг 170 Гц, центр 1700 Гц (1615 = "1"/B, 1785 = "0"/Y).
// Символ 10 бит: 7 инф. (LSB первым) + 3 проверочных (число нулей, MSB первым).
// Кадр: точки -> фазировка (DX=125, RX=111..104) -> F F A.. C S.. [MSG..] EOS ECC.

import Foundation

public enum Selcall {
    public static let baud = 100.0
    public static let defaultCenter = 1700.0
    public static let shift = 170.0

    public static let fmtSelcall = 120
    public static let catRoutine = 100
    public static let eosAckRQ = 117
    public static let eosAckBQ = 122
    public static let eosEOS = 127
    public static let eosSet: Set<Int> = [117, 122, 127]

    static let phaseDX = 125
    static let phaseRX = [111, 110, 109, 108, 107, 106, 105, 104]
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
        let info = [format] + a + [category] + s + m + [eos]
        let ecc = info.reduce(0, ^)
        let body = [format] + info + [ecc]
        let dx = [Int](repeating: phaseDX, count: 6) + body + [eos, eos]
        let rx = phaseRX + body
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

    public static func modulate(_ stream: [Int], sampleRate fs: Double, dotSeconds: Double = 2.0,
                                center: Double = defaultCenter, amplitude: Double = 0.5) -> [Float] {
        let ndots = Int(dotSeconds * baud) / 2 * 2
        var bits = [UInt8]()
        bits.reserveCapacity(ndots + stream.count * 10)
        for i in 0..<ndots { bits.append(i % 2 == 0 ? 1 : 0) }
        for v in stream { bits += symBits(v) }
        let n = Int((Double(bits.count) * fs / baud).rounded())
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        let f1 = center - shift / 2, f0 = center + shift / 2
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

    /// |Y(f1)| - |Y(f0)| со скользящим окном длиной в бит (как numpy convolve mode="same").
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
        let m1 = mag(center - shift / 2), m0 = mag(center + shift / 2)
        var d = [Float](repeating: 0, count: n)
        for i in 0..<n { d[i] = Float(m1[i] - m0[i]) }
        return d
    }

    struct Found {
        var pos: Int
        var score: Int
        var call: DecodedCall
    }

    static let template: [(slot: Int, val: Int)] = {
        var t = [(slot: Int, val: Int)]()
        for i in 0..<6 { t.append((slot: 2 * i, val: phaseDX)) }
        for i in 0..<8 { t.append((slot: 2 * i + 1, val: phaseRX[i])) }
        return t
    }()

    static func findCalls(bits: [UInt8]) -> [Found] {
        let N = bits.count
        guard N >= 400 else { return [] }
        let M = N - 9
        var sym = [Int16](repeating: -1, count: M)
        for n in 0..<M {
            var w = 0
            for i in 0..<10 { w |= Int(bits[n + i]) << i }
            sym[n] = symLUT[w]
        }
        let span = 160
        guard M > span else { return [] }
        let P = M - span
        var cands = [(pos: Int, score: Int)]()
        for p in 0..<P {
            var sc = 0
            for t in template where Int(sym[p + t.slot * 10]) == t.val { sc += 1 }
            if sc >= 8 { cands.append((p, sc)) }
        }
        cands.sort { $0.score != $1.score ? $0.score > $1.score : $0.pos < $1.pos }
        var taken = [Int]()
        var out = [Found]()
        for c in cands where taken.allSatisfy({ abs($0 - c.pos) > 200 }) {
            taken.append(c.pos)
            if let call = extract(sym, c.pos) {
                out.append(Found(pos: c.pos, score: c.score, call: call))
            }
        }
        return out
    }

    static func extract(_ sym: [Int16], _ p: Int, maxBody: Int = 90) -> DecodedCall? {
        let M = sym.count
        func slot(_ i: Int) -> Int? {
            let j = p + 10 * i
            guard j < M else { return nil }
            let v = Int(sym[j])
            return v >= 0 ? v : nil
        }
        var body = [Int?](), conf = [Bool]()
        for k in 0..<maxBody {
            let d = slot(2 * (6 + k))        // DX копия
            let r = slot(2 * (8 + k) + 1)    // RX копия
            if let d = d {
                body.append(d)
                conf.append(r != nil && r! != d)
            } else {
                body.append(r)
                conf.append(false)
            }
        }
        return parse(body, conf)
    }

    static func parse(_ body: [Int?], _ conf: [Bool]) -> DecodedCall? {
        guard body.count > 2, let fmt = body[0] ?? body[1] else { return nil }
        var i = 2
        var addr = [Int]()
        while i < body.count, let v = body[i], v < 100, addr.count < 5 {
            addr.append(v)
            i += 1
        }
        guard !addr.isEmpty, i < body.count, let category = body[i] else { return nil }
        i += 1
        guard i + addr.count <= body.count else { return nil }
        var selfID = [Int]()
        for k in i..<(i + addr.count) {
            guard let v = body[k], v < 100 else { return nil }
            selfID.append(v)
        }
        i += addr.count
        let head = [fmt] + addr + [category] + selfID
        var best: (j: Int, ok: Bool)? = nil
        let upper = min(body.count - 1, i + maxMessage + 1)
        if upper > i {
            for j in i..<upper {
                guard let e = body[j], eosSet.contains(e) else { continue }
                let msg = body[i..<j]
                var ok = false
                if msg.allSatisfy({ $0 != nil }), let eccRx = body[j + 1] {
                    let ecc = (head + msg.map { $0! } + [e]).reduce(0, ^)
                    ok = (ecc == eccRx)
                }
                if ok { best = (j, true); break }
                if best == nil { best = (j, false) }
            }
        }
        guard let b = best, let eos = body[b.j] else { return nil }
        let msgSyms = Array(body[i..<b.j])
        let conflicts = conf.prefix(b.j + 2).filter { $0 }.count
        return DecodedCall(time: 0, format: fmt, to: symsToId(addr), from: symsToId(selfID),
                           category: category,
                           message: msgSyms.isEmpty ? "" : symsToMessage(msgSyms),
                           eos: eos, eccOK: b.ok, conflicts: conflicts,
                           center: 0, inverted: false, phasingScore: 0)
    }

    /// Декодирование на одном центре. `x` — моно, любая fs (быстрее всего 8000).
    static func decodeAt(_ x: [Float], fs: Double, center: Double) -> [DecodedCall] {
        let d = toneDiff(x, fs: fs, center: center)
        let spb = fs / baud
        var found = [DecodedCall]()
        for k in 0..<8 {
            let ph = Double(k) * spb / 8
            let count = Int((Double(d.count) - ph) / spb)
            guard count >= 400 else { continue }
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
                    c.time = Double(idx[f.pos]) / fs
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
    public var eccOK: Bool
    public var conflicts: Int
    public var center: Double
    public var inverted: Bool
    public var phasingScore: Int

    public var isMessage: Bool { !message.isEmpty }
    public var eosName: String { Selcall.eosName(eos) }

    public var summary: String {
        var s = String(format: "[%7.2fs] %@ %@ -> %@", time, isMessage ? "MESSAGE" : "SELCALL", from, to)
        if isMessage { s += "  \"\(message)\"" }
        s += String(format: "  fmt=%d cat=%d %@ ECC:%@  f0=%.1fHz %@", format, category, eosName,
                    eccOK ? "ok" : "BAD", center, inverted ? "inverted" : "normal")
        if conflicts > 0 { s += " conflicts=\(conflicts)" }
        return s
    }
}
