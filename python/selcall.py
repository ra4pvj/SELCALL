#!/usr/bin/env python3
"""
HF Selcall (CCIR 493-4, CODAN/Barrett-compatible) — кодер и декодер.
Поддерживаются: Selcall (индивидуальный вызов) и Message call (текст).

Физика:   FSK 100 бод, сдвиг 170 Гц, центр 1785 Гц (1870 = "1", 1700 = "0" в USB)
Символ:   10 бит = 7 инф. (LSB первым) + 3 проверочных (число нулей, MSB первым)
Кадр (по реальной записи, SELCALL_from_1111_to_1234.wav):
          DX: 125 x6 | F     A.. C S.. [MSG..] EOS EOS EOS
          RX: 109..104 | F F F A.. C S.. [MSG..] EOS
          RX-копия отстаёт от DX на 5 символов. Символа ECC в записи нет.
Декодер понимает и этот кадр, и вариант M.493 (8 RX фазировки, F F, ECC).

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
F_CENTER = 1785.0
SHIFT = 170.0

FMT_SELCALL = 120          # индивидуальный вызов
CAT_ROUTINE = 100          # категория "routine"
EOS_ACK_RQ = 117           # конец, требуется подтверждение
EOS_ACK_BQ = 122           # конец, это подтверждение
EOS_EOS = 127              # просто конец
EOS_SET = (EOS_ACK_RQ, EOS_ACK_BQ, EOS_EOS)
EOS_NAMES = {EOS_ACK_RQ: "ACK-RQ", EOS_ACK_BQ: "ACK-BQ", EOS_EOS: "EOS"}

PHASE_DX = 125
PHASE_RX = list(range(109, 103, -1))   # 109..104 (RX5..RX0), как в записи CODAN
RX_PHASING = set(range(104, 112))
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
    """Поток символов в порядке передачи (DX, RX, DX, RX ...), кадр как в записи CODAN."""
    to_s = "".join(ch for ch in str(to_id) if ch.isdigit())
    fr_s = "".join(ch for ch in str(from_id) if ch.isdigit())
    n = max(len(to_s), len(fr_s))
    a, s = id_to_syms(to_s.zfill(n)), id_to_syms(fr_s.zfill(n))
    m = msg_to_syms(message) if message else []
    rest = a + [category] + s + m
    dx = [PHASE_DX] * 6 + [fmt] + rest + [eos] * 3
    rx = PHASE_RX + [fmt] * 3 + rest + [eos]
    stream = []
    for d, r in zip(dx, rx):
        stream += [d, r]
    return stream


def modulate(stream, fs=48000, dot_seconds=6.0, center=F_CENTER, amp=0.5):
    ndots = int(dot_seconds * BAUD) // 2 * 2
    bits = [1, 0] * (ndots // 2)
    for v in stream:
        bits += sym_bits(v)
    bits = np.array(bits)
    nsamp = int(round(len(bits) * fs / BAUD))
    t = np.arange(nsamp)
    bit_idx = np.minimum((t * BAUD / fs).astype(int), len(bits) - 1)
    f = np.where(bits[bit_idx] == 1, center + SHIFT / 2, center - SHIFT / 2)
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
    x = np.asarray(x, dtype=np.float64)
    N = len(x)
    n = np.arange(N)
    L = max(1, int(round(fs / BAUD)))
    k = np.arange(N)
    lo = np.clip(k - L // 2, 0, N)
    hi = np.clip(k - L // 2 + L, 0, N)

    def mag(f):
        # скользящее среднее длиной в бит через кумулятивную сумму (O(N))
        c = np.concatenate(([0j], np.cumsum(x * np.exp(-2j * np.pi * f * n / fs))))
        return np.abs(c[hi] - c[lo]) / L

    return mag(center + SHIFT / 2) - mag(center - SHIFT / 2)   # >0 => бит "1" (верхний тон)


def _find_calls_in_bits(bits):
    """Ищем фазировку. Якорь q — позиция (в битах) символа RX0 = 104.
    Счёт: RX-фазировка 104+i в q-20i и DX 125 в q-10-20m. Подходит и для
    короткой (6 RX, CODAN), и для полной (8 RX, M.493) фазировки."""
    N = len(bits)
    if N < 200:
        return []
    M = N - 9
    w = np.zeros(M, dtype=np.int32)
    for i in range(10):
        w += bits[i:i + M].astype(np.int32) << i
    sym = SYM_LUT[w]
    PAD = 200
    sp = np.concatenate([np.full(PAD, -1, np.int16), sym, np.full(PAD, -1, np.int16)])
    q = np.arange(PAD, PAD + M)
    score = np.zeros(M, dtype=np.int16)
    for i in range(8):
        score += sp[q - 20 * i] == 104 + i
        score += sp[q - 10 - 20 * i] == PHASE_DX
    cand = np.where(score >= 7)[0]
    order = cand[np.argsort(-score[cand], kind="stable")]
    taken, calls = [], []
    for p in order:
        if any(abs(p - t) <= 200 for t in taken):
            continue
        taken.append(p)
        res = _extract(sym, int(p))
        if res:
            res["endbit"] = int(p) + res.pop("_endrel")
            res["bitpos"] = int(p)                         # якорь RX0 (точная метка)
            res["phasing_score"] = int(score[p])
            calls.append(res)
    return calls


def _extract(sym, q, max_len=90):
    """Логическая последовательность L[k]: DX в q+10+20k и его RX-копия в q+60+20k."""
    M = len(sym)

    def at(j):
        if j < 0 or j >= M:
            return None
        v = int(sym[j])
        return v if v >= 0 else None

    L = []
    for k in range(-2, max_len):
        d, r = at(q + 10 + 20 * k), at(q + 60 + 20 * k)
        if d == PHASE_DX:
            d = None
        if r in RX_PHASING:
            r = None
        if d is None and r is None:
            L.append((None, False, 0))
        elif d is None or r is None:
            L.append((d if r is None else r, False, 1))
        else:
            L.append((d, d != r, 2 if d == r else 1))
        if d is None and r is None and k > 6 and all(v is None for v, _, _ in L[-3:]):
            break
    return _parse(L)


def _parse(L):
    vals = [v for v, _, _ in L]
    i = 0
    while i < len(vals) and i < 3 and vals[i] is None:
        i += 1
    if i >= len(vals) or vals[i] is None or vals[i] < 100 or vals[i] in EOS_SET:
        return None
    fmt = vals[i]
    i += 1
    while i < len(vals) and vals[i] == fmt:
        i += 1
    addr = []
    while i < len(vals) and vals[i] is not None and vals[i] < 100 and len(addr) < 5:
        addr.append(vals[i]); i += 1
    if not addr or i >= len(vals) or vals[i] is None or vals[i] < 100:
        return None
    category = vals[i]; i += 1
    selfid = vals[i:i + len(addr)]
    if len(selfid) < len(addr) or any(v is None or v >= 100 for v in selfid):
        return None
    i += len(addr)
    head = [fmt] + addr + [category] + selfid
    best = None
    for j in range(i, min(len(vals), i + MAX_MSG + 1)):
        if vals[j] not in EOS_SET:
            continue
        msg = vals[i:j]
        nxt = vals[j + 1] if j + 1 < len(vals) else None
        if any(v is None for v in msg):
            status = "BAD"
        else:
            ecc = reduce(lambda x, y: x ^ y, head + msg + [vals[j]])
            if nxt == ecc:
                status = "ok"
            elif nxt is None or nxt == vals[j]:
                status = "нет"
            else:
                status = "BAD"
        if status != "BAD":
            best = (j, status, nxt is not None); break
        if best is None:
            best = (j, status, nxt is not None)
    if best is None:
        return None
    j, status, complete = best
    msg = vals[i:j]
    seg = L[:j + 1]
    conflicts = sum(1 for _, c, _ in seg if c)
    single = sum(1 for v, c, n in seg if v is not None and n == 1)
    valid = status == "ok" or (status == "нет" and conflicts == 0 and None not in head + msg)
    return {
        "type": "message" if msg else "selcall",
        "format": fmt,
        "to": syms_to_id(addr),
        "from": syms_to_id(selfid),
        "category": category,
        "message": syms_to_msg(msg) if msg else "",
        "eos": EOS_NAMES.get(vals[j], vals[j]),
        "ecc": status,
        "ecc_ok": valid,
        "dx_rx_conflicts": conflicts,
        "single_copy": single,
        "complete": complete,                 # после EOS виден ещё символ — кадр точно закончен
        "_endrel": 70 + 20 * (j - 2),         # конец кадра в битах относительно якоря
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
        if len(idx) < 200:
            continue
        raw = d[idx] > 0
        for bits, pol in ((raw, "normal"), (~raw, "inverted")):
            for c in _find_calls_in_bits(bits.astype(np.uint8)):
                # начало фазировки = якорь − 2,3 с; без обрезки по краю окна (иначе при сдвиге
                # окна время «плыло» и потоковый приёмник выдавал тот же вызов повторно)
                c["time"] = idx[c["bitpos"]] / fs - 2.3
                c["end_time"] = idx[min(len(idx) - 1, c.pop("endbit"))] / fs
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


class StreamReceiver:
    """Потоковый приём: копит отсчёты (fs, лучше 8000) в скользящем окне и
    периодически ищет в нём вызовы. Возвращает только новые вызовы, время — от старта."""

    def __init__(self, fs=8000, window=25.0, afc_seconds=20.0):
        self.fs = fs
        self.window = window
        self.afc_seconds = afc_seconds
        self.fixed_center = None
        self.last_centers = []
        self.repeat_window = 8.0     # дубль того же вызова (сдвиг окна); настоящий повтор раньше 8 с не начнётся
        self.reset()

    def reset(self):
        self.buf = np.zeros(0, dtype=np.float32)
        self.base = 0
        self.reported = []
        self.recent = {}            # (от, кому, текст, EOS) -> время: повтор в течение repeat_window не выдаётся

    @property
    def now(self):
        return (self.base + len(self.buf)) / self.fs

    def append(self, x):
        self.buf = np.concatenate((self.buf, np.asarray(x, dtype=np.float32)))
        maxlen = int(self.window * self.fs)
        if len(self.buf) > maxlen:
            drop = len(self.buf) - maxlen
            self.buf = self.buf[drop:]
            self.base += drop

    def process(self, flush=False):
        fs = self.fs
        if len(self.buf) < 2 * fs:
            return []
        x = self.buf.astype(np.float64)
        if self.fixed_center is not None:
            centers = [self.fixed_center]
        else:
            centers = estimate_centers(x[-int(self.afc_seconds * fs):], fs)
            if not any(abs(c - F_CENTER) < 20 for c in centers):
                centers.append(F_CENTER)
        self.last_centers = centers
        found = []
        for c0 in centers:
            found += _decode_at(x, fs, c0)
        t0 = self.base / fs
        end = self.now
        out = []
        for c in _merge(found):
            abs_t = t0 + c["time"]
            if any(abs(r - abs_t) < 1.0 for r in self.reported):
                continue
            key = (c["from"], c["to"], c["message"], c["eos"])
            prev = self.recent.get(key)
            if prev is not None and abs(abs_t - prev) < self.repeat_window:
                continue
            # нет символа после EOS: ждём 1,5 с (EOS мог оказаться буквой текста)
            if not c["complete"] and not flush and end - (t0 + c["end_time"]) < 1.5:
                continue
            if not c["ecc_ok"] and not flush and end - abs_t < 20:
                continue
            c["time"] = abs_t
            c["end_time"] += t0
            self.reported.append(abs_t)
            if c["ecc_ok"]:
                self.recent[key] = abs_t
            out.append(c)
        self.reported = [r for r in self.reported if r > t0 - 5]
        self.recent = {k: v for k, v in self.recent.items() if end - v < self.repeat_window + 60}
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
        if sw == 3:
            b = np.frombuffer(raw, np.uint8).reshape(-1, 3).astype(np.int32)
            v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
            v = np.where(v & 0x800000, v - 0x1000000, v)
            x = v.astype(np.float64) / 2 ** 23
        elif sw == 2:
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
    s += "  fmt=%s cat=%s %s ECC:%s %s  f0=%.1fHz %s" % (
        c["format"], c["category"], c["eos"], c["ecc"], "OK" if c["ecc_ok"] else "СОМНИТЕЛЬНО",
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
    rx = StreamReceiver(8000)
    x8 = np.interp(np.arange(0, len(x), 6.0), np.arange(len(x)), x)   # 48k -> 8k (тест)
    got = []
    for i in range(0, len(x8), 800):
        rx.append(x8[i:i + 800])
        if (i // 800) % 10 == 9:
            got += rx.process()
    rx.append(np.zeros(16000))
    got += rx.process(flush=True)
    for i in range(0, 8000 * 70, 800):                 # ещё 70 с тишины: окно уезжает, повторов быть не должно
        rx.append(np.zeros(800))
        if (i // 800) % 10 == 9:
            got += rx.process()
    # тот же вызов ещё дважды (через ~15 с): оба должны быть приняты — одинаковые вызовы не глушатся
    same = modulate(build_call("1234", "5678"), 8000, 6.0, 1785)
    for rep_ in range(2):
        z = np.concatenate((same, np.zeros(8000 * 3)))
        for i in range(0, len(z), 800):
            rx.append(z[i:i + 800])
            if (i // 800) % 10 == 9:
                got += rx.process()
    for i in range(0, 8000 * 40, 800):
        rx.append(np.zeros(800))
        if (i // 800) % 10 == 9:
            got += rx.process()
    stream_ok = len(got) == len(tests) + 2 and all(c["ecc_ok"] for c in got)
    print("stream decode:", "OK" if stream_ok else "FAIL (%d)" % len(got))
    ok = ok and stream_ok
    ref = [125, 109, 125, 108, 125, 107, 125, 106, 125, 105, 125, 104, 120, 120, 12, 120, 34, 120,
           100, 12, 11, 34, 11, 100, 117, 11, 117, 11, 117, 117]
    frame_ok = build_call("1234", "1111") == ref
    print("frame matches CODAN recording:", "OK" if frame_ok else "FAIL")
    ok = ok and frame_ok
    import os
    rec = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "testdata",
                       "SELCALL_from_1111_to_1234.wav")
    if os.path.exists(rec):
        x, rfs = read_wav(rec)
        r = decode(x, rfs)
        for c in r:
            print(" ", fmt_call(c))
        rec_ok = len(r) == 1 and r[0]["from"] == "1111" and r[0]["to"] == "1234" and r[0]["ecc_ok"]
        print("real recording 1111 -> 1234:", "OK" if rec_ok else "FAIL")
        ok = ok and rec_ok
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
    e.add_argument("--dot", type=float, default=6.0, help="длина точек, с (для сканирующих приёмников 6+)")
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
