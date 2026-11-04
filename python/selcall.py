#!/usr/bin/env python3
"""
HF Selcall (CCIR 493-4, CODAN/Barrett-compatible) — кодер и декодер.
Поддерживаются: Selcall (индивидуальный вызов) и Message call (текст).

Физика:   FSK 100 бод, сдвиг 170 Гц, центр 1700 Гц (1615 = "1"/B, 1785 = "0"/Y)
Символ:   10 бит = 7 инф. (LSB первым) + 3 проверочных (число нулей, MSB первым)
Кадр:     точки -> фазировка (DX=125, RX=111..104) -> F F A.. C S.. [MSG..] EOS ECC
          каждый символ передаётся дважды (DX и RX, RX отстаёт на 2 пары слотов)

Использование:
  python selcall.py encode --to 1234 --from 5678 -o call.wav
  python selcall.py encode --to 1234 --from 5678 --msg "HELLO" -o msg.wav
  python selcall.py decode record.wav            (частота центра ищется автоматически)
  python selcall.py selftest
"""
import argparse
import sys
import wave
from functools import reduce

import numpy as np

# ---------------------------------------------------------------- константы
BAUD = 100.0
F_CENTER = 1700.0
SHIFT = 170.0

FMT_SELCALL = 120          # индивидуальный вызов
CAT_ROUTINE = 100          # категория "routine"
EOS_ACK_RQ = 117           # конец, требуется подтверждение
EOS_ACK_BQ = 122           # конец, это подтверждение
EOS_EOS = 127              # просто конец
EOS_SET = (EOS_ACK_RQ, EOS_ACK_BQ, EOS_EOS)
EOS_NAMES = {EOS_ACK_RQ: "ACK-RQ", EOS_ACK_BQ: "ACK-BQ", EOS_EOS: "EOS"}

PHASE_DX = 125
PHASE_RX = list(range(111, 103, -1))   # 111,110,...,104 (RX7..RX0)
MAX_MSG = 64


# ---------------------------------------------------------------- символы
def sym_bits(v):
    """10 бит символа в порядке передачи."""
    info = [(v >> i) & 1 for i in range(7)]
    zeros = 7 - sum(info)
    return info + [(zeros >> 2) & 1, (zeros >> 1) & 1, zeros & 1]


def _pack(bits):
    return sum(int(b) << i for i, b in enumerate(bits))


SYM_LUT = np.full(1024, -1, dtype=np.int16)      # 10-битное слово -> символ или -1
for _v in range(128):
    SYM_LUT[_pack(sym_bits(_v))] = _v


def id_to_syms(ident):
    s = "".join(ch for ch in str(ident) if ch.isdigit())
    if not s:
        raise ValueError("ID должен состоять из цифр")
    if len(s) % 2:
        s = "0" + s
    return [int(s[i:i + 2]) for i in range(0, len(s), 2)]


def syms_to_id(syms):
    return "".join("%02d" % v for v in syms)


# --- кодирование текста Message call.
# ВНИМАНИЕ: раскладка текста в CODAN Message call официально не опубликована.
# Здесь гипотеза: каждый символ текста = один 7-битный символ ASCII между
# self-ID и EOS. Проверить/исправить по реальной записи с рации CODAN.
def msg_to_syms(text):
    out = []
    for ch in text[:MAX_MSG]:
        c = ord(ch)
        out.append(c if 32 <= c <= 126 else ord("?"))
    return out


def syms_to_msg(syms):
    return "".join(chr(v) if v is not None and 32 <= v <= 126 else "\ufffd" for v in syms)


# ---------------------------------------------------------------- кодер
def build_call(to_id, from_id, message=None, fmt=FMT_SELCALL,
               category=CAT_ROUTINE, eos=EOS_ACK_RQ):
    """Возвращает поток символов в порядке передачи (DX, RX, DX, RX ...)."""
    to_s, fr_s = str(to_id), str(from_id)
    n = max(len(to_s), len(fr_s))
    a, s = id_to_syms(to_s.zfill(n)), id_to_syms(fr_s.zfill(n))
    m = msg_to_syms(message) if message else []
    info = [fmt] + a + [category] + s + m + [eos]
    ecc = reduce(lambda x, y: x ^ y, info)
    body = [fmt] + info + [ecc]                 # format specifier передаётся дважды
    dx = [PHASE_DX] * 6 + body + [eos, eos]     # EOS трижды в DX
    rx = PHASE_RX + body
    stream = []
    for d, r in zip(dx, rx):
        stream += [d, r]
    return stream


def modulate(stream, fs=48000, dot_seconds=2.0, center=F_CENTER, amp=0.5):
    ndots = int(dot_seconds * BAUD) // 2 * 2
    bits = [1, 0] * (ndots // 2)
    for v in stream:
        bits += sym_bits(v)
    bits = np.array(bits)
    nsamp = int(round(len(bits) * fs / BAUD))
    t = np.arange(nsamp)
    bit_idx = np.minimum((t * BAUD / fs).astype(int), len(bits) - 1)
    f = np.where(bits[bit_idx] == 1, center - SHIFT / 2, center + SHIFT / 2)
    phase = 2 * np.pi * np.cumsum(f) / fs            # непрерывная фаза
    y = amp * np.sin(phase)
    ramp = int(0.005 * fs)                           # 5 мс плавные края
    w = np.ones(nsamp)
    w[:ramp] = np.linspace(0, 1, ramp)
    w[-ramp:] = np.linspace(1, 0, ramp)
    return (y * w).astype(np.float32)


# ---------------------------------------------------------------- демодулятор
def estimate_centers(x, fs, lo=1000.0, hi=2600.0, top=3):
    """АПЧ: спектрограмма (кадр 20 мс). Для каждого кандидата центра c считаем
    сумму по кадрам |E(c-85) - E(c+85)| / E_кадра. У FSK в каждом кадре горит
    один из двух тонов, поэтому метрика максимальна на верном центре, а шум даёт
    ровный фон. Возвращает до `top` лучших центров (разнос > 40 Гц)."""
    win_len = max(16, int(0.02 * fs))
    hop = win_len // 2
    df = 2.5
    nfft = int(round(fs / df))
    if len(x) < win_len * 4:
        return [F_CENTER]
    nfr = (len(x) - win_len) // hop + 1
    w = np.hanning(win_len)
    k_lo = int(round((lo - SHIFT / 2) / df))
    k_hi = int(round((hi + SHIFT / 2) / df))
    sh = int(round(SHIFT / df))                            # 68 бинов
    score = np.zeros(k_hi - k_lo - sh + 1)
    for st in range(0, nfr, 1000):
        fr = np.arange(st, min(nfr, st + 1000))
        idx = fr[:, None] * hop + np.arange(win_len)[None, :]
        E = np.abs(np.fft.rfft(x[idx] * w, nfft, axis=1)[:, k_lo:k_hi + 1]) ** 2
        E /= E.sum(axis=1, keepdims=True) + 1e-20
        score += np.abs(E[:, :-sh] - E[:, sh:]).sum(axis=0)
    cands = (k_lo + np.arange(len(score))) * df + SHIFT / 2
    picked = []
    for i in np.argsort(-score):
        c = float(cands[i])
        if all(abs(c - p) > 40 for p in picked):
            picked.append(c)
        if len(picked) >= top:
            break
    return picked


def estimate_center(x, fs):
    return estimate_centers(x, fs, top=1)[0]


def tone_diff(x, fs, center):
    n = np.arange(len(x))
    L = max(1, int(round(fs / BAUD)))
    k = np.ones(L) / L

    def mag(f):
        y = x * np.exp(-2j * np.pi * f * n / fs)
        return np.abs(np.convolve(y, k, mode="same"))

    return mag(center - SHIFT / 2) - mag(center + SHIFT / 2)   # >0 => бит "1"


# phasing template: (слот в потоке, символ)
_TEMPLATE = [(2 * i, PHASE_DX) for i in range(6)] + \
            [(2 * i + 1, PHASE_RX[i]) for i in range(8)]


def _find_calls_in_bits(bits):
    N = len(bits)
    if N < 400:
        return []
    M = N - 9
    w = np.zeros(M, dtype=np.int32)
    for i in range(10):
        w += bits[i:i + M].astype(np.int32) << i
    sym = SYM_LUT[w]
    span = 10 * 16
    if M <= span:
        return []
    P = M - span
    score = np.zeros(P, dtype=np.int16)
    for slot, val in _TEMPLATE:
        score += (sym[slot * 10: slot * 10 + P] == val)
    cand = np.where(score >= 8)[0]
    # подавление немаксимумов
    order = cand[np.argsort(-score[cand], kind="stable")]
    taken, starts = [], []
    for p in order:
        if all(abs(p - q) > 200 for q in taken):
            taken.append(p)
            starts.append((int(p), int(score[p])))
    calls = []
    for p, sc in starts:
        res = _extract(sym, p)
        if res:
            res["bitpos"] = p
            res["phasing_score"] = sc
            calls.append(res)
    return calls


def _extract(sym, p, max_body=90):
    M = len(sym)

    def slot(i):
        j = p + 10 * i
        if j >= M:
            return None
        v = int(sym[j])
        return v if v >= 0 else None

    body, conf = [], []
    for k in range(max_body):
        d = slot(2 * (6 + k))          # DX копия
        r = slot(2 * (8 + k) + 1)      # RX копия
        if d is None:
            body.append(r); conf.append(False)
        else:
            body.append(d); conf.append(r is not None and r != d)
    return _parse(body, conf)


def _parse(body, conf):
    fmt = body[0] if body[0] is not None else body[1]
    if fmt is None:
        return None
    i = 2
    addr = []
    while i < len(body) and body[i] is not None and body[i] < 100 and len(addr) < 5:
        addr.append(body[i]); i += 1
    if not addr or i >= len(body) or body[i] is None:
        return None
    category = body[i]; i += 1
    selfid = body[i:i + len(addr)]
    if len(selfid) < len(addr) or any(v is None or v >= 100 for v in selfid):
        return None
    i += len(addr)
    head = [fmt] + addr + [category] + selfid
    best = None
    for j in range(i, min(len(body) - 1, i + MAX_MSG + 1)):
        if body[j] in EOS_SET:
            msg = body[i:j]
            if any(v is None for v in msg):
                ecc_ok = False
            else:
                ecc_ok = reduce(lambda x, y: x ^ y, head + msg + [body[j]]) == body[j + 1]
            if ecc_ok:
                best = (j, True); break
            if best is None:
                best = (j, False)
    if best is None:
        return None
    j, ecc_ok = best
    msg = body[i:j]
    return {
        "type": "message" if msg else "selcall",
        "format": fmt,
        "to": syms_to_id(addr),
        "from": syms_to_id(selfid),
        "category": category,
        "message": syms_to_msg(msg) if msg else "",
        "eos": EOS_NAMES.get(body[j], body[j]),
        "ecc_ok": ecc_ok,
        "dx_rx_conflicts": int(sum(conf[:j + 2])),
    }


def decode(x, fs, center=None):
    x = np.asarray(x, dtype=np.float64)
    centers = [center] if center is not None else estimate_centers(x, fs)
    found = []
    for c0 in centers:
        found += _decode_at(x, fs, c0)
    return _merge(found)


def _decode_at(x, fs, center):
    d = tone_diff(x, fs, center)
    spb = fs / BAUD
    found = []
    for ph in np.arange(0, spb, spb / 8):
        idx = (ph + np.arange(int((len(d) - ph) / spb)) * spb).astype(int)
        if len(idx) < 400:
            continue
        raw = d[idx] > 0
        for bits, pol in ((raw, "normal"), (~raw, "inverted")):
            for c in _find_calls_in_bits(bits.astype(np.uint8)):
                c["time"] = idx[c["bitpos"]] / fs
                c["polarity"] = pol
                c["center_hz"] = round(center, 1)
                found.append(c)
    return found


def _merge(found):
    # объединяем дубли от разных центров/фаз/полярностей
    found.sort(key=lambda c: (not c["ecc_ok"], c["dx_rx_conflicts"], -c["phasing_score"]))
    out = []
    for c in found:
        if all(abs(c["time"] - o["time"]) > 0.3 for o in out):
            out.append(c)
    out.sort(key=lambda c: c["time"])
    for c in out:
        c.pop("bitpos", None)
    return out


# ---------------------------------------------------------------- WAV
def write_wav(path, y, fs):
    pcm = np.clip(y, -1, 1)
    pcm = (pcm * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(fs)
        w.writeframes(pcm.tobytes())


def read_wav(path):
    try:
        with wave.open(path, "rb") as w:
            fs, ch, sw = w.getframerate(), w.getnchannels(), w.getsampwidth()
            raw = w.readframes(w.getnframes())
        if sw == 2:
            x = np.frombuffer(raw, "<i2").astype(np.float64) / 32768
        elif sw == 1:
            x = (np.frombuffer(raw, np.uint8).astype(np.float64) - 128) / 128
        elif sw == 4:
            x = np.frombuffer(raw, "<i4").astype(np.float64) / 2 ** 31
        else:
            raise ValueError("sample width %d" % sw)
        return x.reshape(-1, ch)[:, 0], fs
    except (wave.Error, ValueError):
        from scipy.io import wavfile           # float WAV и пр.
        fs, x = wavfile.read(path)
        x = x.astype(np.float64)
        if x.ndim > 1:
            x = x[:, 0]
        if np.abs(x).max() > 1.5:
            x /= np.abs(x).max()
        return x, fs


# ---------------------------------------------------------------- CLI
def fmt_call(c):
    s = "[%7.2fs] %-7s %s -> %s" % (c["time"], c["type"].upper(), c["from"], c["to"])
    if c["message"]:
        s += '  "%s"' % c["message"]
    s += "  fmt=%s cat=%s %s ECC:%s  f0=%.1fHz %s" % (
        c["format"], c["category"], c["eos"], "ok" if c["ecc_ok"] else "BAD",
        c["center_hz"], c["polarity"])
    if c["dx_rx_conflicts"]:
        s += " conflicts=%d" % c["dx_rx_conflicts"]
    return s


def selftest():
    fs = 48000
    rng = np.random.default_rng(1)
    parts = [np.zeros(fs // 2)]
    tests = [("1234", "5678", None), ("123456", "654321", "PRIVET, KAK SLYSHNO? 73"),
             ("0042", "0007", "Test message #1")]
    for to, fr, msg in tests:
        parts.append(modulate(build_call(to, fr, msg), fs, dot_seconds=1.0, center=1740))
        parts.append(np.zeros(fs // 2))
    x = np.concatenate(parts)
    x = x + rng.normal(0, 0.35, len(x))                  # сильный шум, расстройка +40 Гц
    write_wav("selftest.wav", x / np.abs(x).max(), fs)
    res = decode(x, fs)
    for c in res:
        print(fmt_call(c))
    ok = len(res) == len(tests) and all(
        c["to"] == t[0] and c["from"] == t[1] and c["message"] == (t[2] or "") and c["ecc_ok"]
        for c, t in zip(res, tests))
    print("SELFTEST", "OK" if ok else "FAIL")
    return ok


def main():
    ap = argparse.ArgumentParser(description="CCIR 493-4 HF Selcall (CODAN) codec")
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("encode")
    e.add_argument("--to", required=True)
    e.add_argument("--from", dest="frm", required=True)
    e.add_argument("--msg")
    e.add_argument("--fmt", type=int, default=FMT_SELCALL)
    e.add_argument("--cat", type=int, default=CAT_ROUTINE)
    e.add_argument("--eos", type=int, default=EOS_ACK_RQ, choices=EOS_SET)
    e.add_argument("--fs", type=int, default=48000)
    e.add_argument("--dot", type=float, default=2.0, help="длина точек, с (для сканирующих приёмников 6+)")
    e.add_argument("--center", type=float, default=F_CENTER)
    e.add_argument("-o", "--out", required=True)
    d = sub.add_parser("decode")
    d.add_argument("wav")
    d.add_argument("--center", type=float, help="центр, Гц (по умолчанию — автоопределение)")
    sub.add_parser("selftest")
    a = ap.parse_args()

    if a.cmd == "encode":
        stream = build_call(a.to, a.frm, a.msg, a.fmt, a.cat, a.eos)
        y = modulate(stream, a.fs, a.dot, a.center)
        write_wav(a.out, y, a.fs)
        print("written %s (%.2f s), symbols: %s" % (a.out, len(y) / a.fs, stream))
    elif a.cmd == "decode":
        x, fs = read_wav(a.wav)
        res = decode(x, fs, a.center)
        if not res:
            print("вызовов не найдено")
        for c in res:
            print(fmt_call(c))
    else:
        sys.exit(0 if selftest() else 1)


if __name__ == "__main__":
    main()
