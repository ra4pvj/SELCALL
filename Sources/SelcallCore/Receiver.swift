// АПЧ и потоковый приёмник.

import Foundation

/// АПЧ: спектрограмма (кадр 20 мс, шаг 10 мс). Для каждого кандидата центра c
/// копится сумма по кадрам |E(c-85) - E(c+85)| / E_кадра. У FSK в каждом кадре
/// горит один из двух тонов, поэтому метрика максимальна на верном центре,
/// а шум даёт ровный фон. Работает инкрементально.
public final class AFC {
    public let fs: Double
    public let lo: Double, hi: Double
    let df = 2.5
    let win: Int, hop: Int
    let kLo: Int, nb: Int, sh: Int
    var cosT: [Float], sinT: [Float]
    var pending = [Float]()
    var total: [Double]
    var history = [[Float]]()
    /// Сколько кадров помнить (nil = без ограничения, для пакетной обработки).
    public var maxFrames: Int?

    public init(sampleRate fs: Double, lo: Double = 1000, hi: Double = 2600, windowSeconds: Double? = nil) {
        self.fs = fs
        self.lo = lo
        self.hi = hi
        // всё считаем в локальных переменных, потом присваиваем (правила инициализации класса)
        let step = 2.5
        let w0 = max(16, Int(0.02 * fs))
        let h0 = max(1, w0 / 2)
        let k0 = Int(((lo - Selcall.shift / 2) / step).rounded())
        let k1 = Int(((hi + Selcall.shift / 2) / step).rounded())
        let n0 = k1 - k0 + 1
        let s0 = Int((Selcall.shift / step).rounded())
        var ct = [Float](repeating: 0, count: n0 * w0)
        var st = [Float](repeating: 0, count: n0 * w0)
        for b in 0..<n0 {
            let f = Double(k0 + b) * step
            for n in 0..<w0 {
                let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(w0 - 1))
                let a = 2 * Double.pi * f * Double(n) / fs
                ct[b * w0 + n] = Float(w * cos(a))
                st[b * w0 + n] = Float(w * sin(a))
            }
        }
        win = w0
        hop = h0
        kLo = k0
        nb = n0
        sh = s0
        cosT = ct
        sinT = st
        total = [Double](repeating: 0, count: n0 - s0)
        maxFrames = windowSeconds.map { Int($0 * fs / Double(h0)) }
    }

    public func reset() {
        pending.removeAll()
        history.removeAll()
        for i in total.indices { total[i] = 0 }
    }

    public func append(_ x: [Float]) {
        pending += x
        var start = 0
        while pending.count - start >= win {
            frame(at: start)
            start += hop
        }
        if start > 0 { pending.removeFirst(start) }
    }

    private func frame(at s: Int) {
        var E = [Float](repeating: 0, count: nb)
        var sum: Float = 0
        pending.withUnsafeBufferPointer { px in
            cosT.withUnsafeBufferPointer { ct in
                sinT.withUnsafeBufferPointer { st in
                    for b in 0..<nb {
                        var re: Float = 0, im: Float = 0
                        let o = b * win
                        for n in 0..<win {
                            let v = px[s + n]
                            re += v * ct[o + n]
                            im += v * st[o + n]
                        }
                        let e = re * re + im * im
                        E[b] = e
                        sum += e
                    }
                }
            }
        }
        guard sum > 1e-20 else { return }
        var vec = [Float](repeating: 0, count: nb - sh)
        for c in 0..<(nb - sh) {
            let v = abs(E[c] - E[c + sh]) / sum
            vec[c] = v
            total[c] += Double(v)
        }
        if let mf = maxFrames {
            history.append(vec)
            if history.count > mf {
                let old = history.removeFirst()
                for c in 0..<old.count { total[c] -= Double(old[c]) }
            }
        }
    }

    /// До `count` лучших центров с разносом > 40 Гц.
    public func topCenters(_ count: Int = 3) -> [Double] {
        let order = total.indices.sorted { total[$0] > total[$1] }
        var picked = [Double]()
        for i in order {
            let c = Double(kLo + i) * df + Selcall.shift / 2
            if c < lo || c > hi { continue }
            if picked.allSatisfy({ abs($0 - c) > 40 }) { picked.append(c) }
            if picked.count >= count { break }
        }
        return picked.isEmpty ? [Selcall.defaultCenter] : picked
    }
}

/// Потоковый приёмник. Принимает моно-отсчёты (рекомендуется 8000 Гц),
/// держит скользящее окно и периодически ищет в нём вызовы.
/// Не потокобезопасен: вызывать с одной очереди.
public final class Receiver {
    public let fs: Double
    public var windowSeconds: Double
    /// nil = автоматическая АПЧ, иначе фиксированный центр.
    public var fixedCenter: Double?
    public private(set) var lastCenters: [Double] = []

    private var buf = [Float]()
    private var base = 0                       // абсолютный индекс buf[0]
    private let afc: AFC
    private var reported = [Double]()          // абсолютные времена выданных вызовов
    /// Недавно выданные вызовы по содержимому (от, кому, текст, EOS) -> абсолютное время:
    /// тот же вызов в пределах `repeatWindow` секунд повторно не выдаётся (защита от дублей при
    /// сдвиге окна анализа). Окно короткое: настоящий повторный вызов раньше 8 с не начнётся.
    private var recent = [String: Double]()
    public var repeatWindow = 8.0

    public init(sampleRate: Double = 8000, windowSeconds: Double = 60) {
        fs = sampleRate
        self.windowSeconds = windowSeconds
        afc = AFC(sampleRate: sampleRate, windowSeconds: 20)
    }

    /// Секунды от старта приёмника (абсолютное время последнего отсчёта).
    public var now: Double { Double(base + buf.count) / fs }

    public func reset() {
        buf.removeAll()
        base = 0
        afc.reset()
        reported.removeAll()
        recent.removeAll()
    }

    public func append(_ x: [Float]) {
        buf += x
        afc.append(x)
        let maxLen = Int(windowSeconds * fs)
        if buf.count > maxLen {
            let drop = buf.count - maxLen
            buf.removeFirst(drop)
            base += drop
        }
    }

    /// Возвращает новые (ещё не выданные) вызовы; `time` у них абсолютное.
    /// Вызовы с плохим ECC выдаются только когда точно приняты целиком.
    public func process(flush: Bool = false) -> [DecodedCall] {
        guard buf.count > Int(fs * 2) else { return [] }
        var centers = fixedCenter.map { [$0] } ?? afc.topCenters(3)
        if fixedCenter == nil, !centers.contains(where: { abs($0 - Selcall.defaultCenter) < 20 }) {
            centers.append(Selcall.defaultCenter)
        }
        lastCenters = centers
        var found = [DecodedCall]()
        for c in centers { found += Selcall.decodeAt(buf, fs: fs, center: c) }
        let calls = Selcall.merge(found)
        let t0 = Double(base) / fs
        let end = now
        var out = [DecodedCall]()
        for var c in calls {
            let absT = t0 + c.time
            if reported.contains(where: { abs($0 - absT) < 1.0 }) { continue }
            let key = "\(c.from)|\(c.to)|\(c.message)|\(c.eos)"
            if let prev = recent[key], absT - prev < repeatWindow, absT - prev > -repeatWindow { continue }
            // кадр без завершающего символа после EOS: ждём ещё 1,5 с (EOS мог оказаться буквой текста)
            if !c.complete && !flush && end - (t0 + c.endTime) < 1.5 { continue }
            if !c.eccOK && !flush && end - absT < 20 { continue }
            c.time = absT
            c.endTime += t0
            reported.append(absT)
            if c.eccOK { recent[key] = absT }
            out.append(c)
        }
        reported.removeAll { $0 < t0 - 5 }
        recent = recent.filter { end - $0.value < repeatWindow + 60 }
        return out
    }
}
