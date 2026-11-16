// selcall-cli: кодирование/декодирование WAV и самопроверка ядра.
//   selcall-cli encode --to 1234 --from 5678 [--msg TEXT] [--fs 48000] [--dot 2] [--center 1700] -o out.wav
//   selcall-cli decode file.wav [--center 1700]
//   selcall-cli selftest

import Foundation
import SelcallCore

func usage() -> Never {
    print("""
    usage:
      selcall-cli encode --to ID --from ID [--msg TEXT] [--fs 48000] [--dot 6.0] [--center 1700] [--eos 117|122|127] -o out.wav
      selcall-cli decode file.wav [--center HZ]
      selcall-cli selftest
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
args.removeFirst()

func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Гауссов шум (Box–Muller на детерминированном LCG).
struct Noise {
    var s: UInt64
    mutating func uniform() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
    mutating func gauss() -> Double {
        let u1 = max(1e-12, uniform()), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

func decodeFile(_ samples: [Float], _ fs: Double, center: Double?) -> [DecodedCall] {
    let x8 = Resampler.resample(samples, from: fs, to: 8000)
    return Selcall.decode(x8, fs: 8000, center: center)
}

switch cmd {
case "encode":
    guard let to = opt("--to"), let from = opt("--from"), let out = opt("-o") ?? opt("--out") else { usage() }
    let fs = Double(opt("--fs") ?? "48000") ?? 48000
    let dot = Double(opt("--dot") ?? "6") ?? 6
    let center = Double(opt("--center") ?? "1700") ?? 1700
    let eos = Int(opt("--eos") ?? "117") ?? 117
    let msg = opt("--msg").map { Translit.latin($0) }
    let stream = Selcall.buildCall(to: to, from: from, message: msg, eos: eos)
    let y = Selcall.modulate(stream, sampleRate: fs, dotSeconds: dot, center: center)
    do {
        try WAV.write(URL(fileURLWithPath: out), samples: y, sampleRate: Int(fs))
        print(String(format: "written %@ (%.2f s), symbols: %@", out, Double(y.count) / fs, stream.description))
    } catch { print("error: \(error)"); exit(1) }

case "decode":
    guard let path = args.first(where: { !$0.hasPrefix("--") }) else { usage() }
    do {
        let (x, fs) = try WAV.read(URL(fileURLWithPath: path))
        let res = decodeFile(x, fs, center: opt("--center").flatMap { Double($0) })
        if res.isEmpty { print("вызовов не найдено") }
        res.forEach { print($0.summary) }
    } catch { print("error: \(error)"); exit(1) }

case "selftest":
    var ok = true
    // 1) пакетный декодер: 3 вызова, шум, расстройка +40 Гц, fs = 8000
    let fs = 8000.0
    let tests: [(String, String, String?)] = [("1234", "5678", nil),
                                              ("123456", "654321", "PRIVET, KAK SLYSHNO? 73"),
                                              ("0042", "0007", "Test message #1")]
    var x = [Float](repeating: 0, count: 4000)
    for t in tests {
        x += Selcall.modulate(Selcall.buildCall(to: t.0, from: t.1, message: t.2), sampleRate: fs,
                              dotSeconds: 1.0, center: 1740)
        x += [Float](repeating: 0, count: 4000)
    }
    var rng = Noise(s: 1)
    let noisy = x.map { $0 + Float(0.35 * rng.gauss()) }
    let res = Selcall.decode(noisy, fs: fs)
    res.forEach { print($0.summary) }
    let batchOK = res.count == tests.count && zip(res, tests).allSatisfy {
        $0.to == $1.0 && $0.from == $1.1 && $0.message == ($1.2 ?? "") && $0.eccOK
    }
    print("batch decode:", batchOK ? "OK" : "FAIL")
    ok = ok && batchOK

    // 2) потоковый приёмник: подаём кусками по 100 мс
    let rx = Receiver(sampleRate: fs, windowSeconds: 60)
    var got = [DecodedCall]()
    var i = 0
    while i < noisy.count {
        let j = min(noisy.count, i + 800)
        rx.append(Array(noisy[i..<j]))
        if (j / 800) % 10 == 0 { got += rx.process() }
        i = j
    }
    rx.append([Float](repeating: 0, count: 16000))
    got += rx.process(flush: true)
    // ещё 90 с тишины: окно приёмника (60 с) уезжает за вызовы — повторов быть не должно
    for k in 0..<90 {
        rx.append([Float](repeating: 0, count: 8000))
        if k % 2 == 1 { got += rx.process() }
    }
    // тот же вызов ещё дважды (через ~15 с): оба должны быть приняты, лишних — нет
    let same = Selcall.modulate(Selcall.buildCall(to: "1234", from: "5678"), sampleRate: fs, dotSeconds: 6.0)
    for _ in 0..<2 {
        let z = same + [Float](repeating: 0, count: 24000)
        var j = 0
        while j < z.count {
            let e = min(z.count, j + 8000)
            rx.append(Array(z[j..<e]))
            got += rx.process()
            j = e
        }
    }
    for _ in 0..<40 {
        rx.append([Float](repeating: 0, count: 8000))
        got += rx.process()
    }
    let streamOK = got.count == tests.count + 2 && got.allSatisfy { $0.eccOK }
    print("stream decode:", streamOK ? "OK" : "FAIL (\(got.count) calls)")
    got.forEach { print("  ", $0.summary) }
    ok = ok && streamOK

    // 3) WAV 48 кГц -> передискретизация -> декодер
    let y = Selcall.modulate(Selcall.buildCall(to: "1234", from: "5678", message: "HELLO 73"),
                             sampleRate: 48000, dotSeconds: 1.0)
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selcall_selftest.wav")
    do {
        try WAV.write(url, samples: y, sampleRate: 48000)
        let (z, zfs) = try WAV.read(url)
        let r = decodeFile(z, zfs, center: nil)
        let wavOK = r.count == 1 && r[0].message == "HELLO 73" && r[0].eccOK
        print("wav 48k roundtrip:", wavOK ? "OK" : "FAIL")
        ok = ok && wavOK
    } catch { print("wav error: \(error)"); ok = false }

    // 4) кодер даёт тот же поток символов, что и реальная запись CODAN
    let reference = [125, 109, 125, 108, 125, 107, 125, 106, 125, 105, 125, 104, 120, 120, 12, 120, 34, 120,
                     100, 12, 11, 34, 11, 100, 117, 11, 117, 11, 117, 117]
    let frameOK = Selcall.buildCall(to: "1234", from: "1111") == reference
    print("frame matches CODAN recording:", frameOK ? "OK" : "FAIL")
    ok = ok && frameOK

    // 5) реальная запись (если запускаем из корня репозитория)
    let rec = URL(fileURLWithPath: "testdata/SELCALL_from_1111_to_1234.wav")
    if FileManager.default.fileExists(atPath: rec.path) {
        do {
            let (z, zfs) = try WAV.read(rec)
            let r = decodeFile(z, zfs, center: nil)
            r.forEach { print("  ", $0.summary) }
            let recOK = r.count == 1 && r[0].from == "1111" && r[0].to == "1234" && r[0].eccOK
            print("real recording 1111 -> 1234:", recOK ? "OK" : "FAIL")
            ok = ok && recOK
        } catch { print("recording error: \(error)"); ok = false }
    } else {
        print("real recording: пропущено (нет testdata/)")
    }

    print("SELFTEST", ok ? "OK" : "FAIL")
    exit(ok ? 0 : 1)

default:
    usage()
}
