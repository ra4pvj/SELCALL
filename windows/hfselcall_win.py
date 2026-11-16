#!/usr/bin/env python3
"""
HF Selcall для Windows (7 SP1 и новее): приём/передача CCIR 493-4 селкола, совместимого с CODAN.
Тот же функционал, что у версии для macOS: Selcall и Message call, АПЧ, журнал, звонок при
вызове на свой ID, управление передачей (VOX или RTS/DTR COM-порта), пауза приёма на время передачи.

Совместимо с Python 3.8 (последний с поддержкой Windows 7): numpy, sounddevice, pyserial, tkinter.
    python hfselcall_win.py            — запуск
    python hfselcall_win.py --selftest — самопроверка (результат в selftest.txt рядом с exe)
"""
import datetime
import json
import os
import queue
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
for _p in (HERE, os.path.join(HERE, "..", "python")):
    if os.path.exists(os.path.join(_p, "selcall.py")):
        sys.path.insert(0, _p)
import selcall as S  # noqa: E402

try:
    import sounddevice as sd
    SD_ERROR = None
except Exception as _ex:  # PortAudio не найден и т.п.
    sd = None
    SD_ERROR = _ex

import selcall_ptt as PTT  # noqa: E402  (модуль PTT/CAT из проекта HFP)
serial = PTT.serial
SERIAL_ERROR = PTT.SERIAL_ERROR

APP_NAME = "HF Selcall"
VERSION = "dev"
try:
    from _version import VERSION  # noqa: F401  (подставляется при сборке)
except Exception:
    pass

RX_FS = 8000
ANSWER_SECONDS = 2.5        # ответ в эфир тонами: 2,5 с (мелодия звучит целиком один раз)
MAX_MSG = S.MAX_MSG


def app_dir():
    if sys.platform.startswith("win"):
        base = os.environ.get("APPDATA", os.path.expanduser("~"))
    elif sys.platform == "darwin":
        base = os.path.join(os.path.expanduser("~"), "Library", "Application Support")
    else:
        base = os.environ.get("XDG_CONFIG_HOME", os.path.join(os.path.expanduser("~"), ".config"))
    d = os.path.join(base, "HFSelcall")
    try:
        os.makedirs(d, exist_ok=True)
    except Exception:
        pass
    return d


APP_DIR = app_dir()
SETTINGS_FILE = os.path.join(APP_DIR, "settings.json")
LOG_FILE = os.path.join(APP_DIR, "journal.log")

DEFAULTS = dict(
    my_id="1234", to_id="", in_dev="", out_dev="",
    dot_seconds=6.0, tx_level=0.5, translit=True,
    afc=True, fixed_center=S.F_CENTER, show_all=True, in_channel=0,
    ptt_method="none", ptt_port="", ptt_baud=9600, ptt_invert=False,
    ptt_icom_model="IC-7300", ptt_icom_addr="94", ptt_kenwood="TX;",
    ptt_delay=0.5, ptt_tail=0.3, mute_rx_on_tx=True,
    mon_devs=[], mon_rx=True, mon_tx=True, mon_level=0.5,
    ring=True, ring_style="codan", answer_style="kalinka", ring_volume=0.5, ring_seconds=30.0,
    ring_air=True,
    ext_enabled=False, ext_port="", ext_line="DTR", ext_invert=False, ext_seconds=5.0,
    listen_after_call=True, listen_seconds=60.0,
)

PTT_TITLES = {"none": "нет (VOX / внешний PTT)", "RTS": "RTS", "DTR": "DTR", "RTS+DTR": "RTS + DTR",
              "ICOM": "ICOM (CI-V)", "YAESU": "YAESU (TX1;/TX0;)", "YAESU-OLD": "YAESU-OLD (FT-817/857/897)",
              "KENWOOD": "KENWOOD (TX;/RX;)", "ELECRAFT": "ELECRAFT (TX;/RX;)"}
IN_CHANNELS = ["Авто (где есть сигнал)", "1 (левый)", "2 (правый)"]
RING_STYLES = [("codan", "Двухтональный"), ("vertex", "Трель"),
               ("beep", "Короткие гудки"), ("kalinka", "Мелодия «Калинка»")]

# Начало припева «Калинки» (И. Ларионов, 1860; общественное достояние) по нотам, на октаву выше записи:
# «ми ре си до ре си до ре до си ля» — E5 | D5 B4 C5 | D5 B4 C5 | D5 C5 B4 | A4
# (частота, Гц; длительность в четвертях, как в нотах: половинная = 2). 16 четвертей по 0,18 с ≈ 2,9 с.
_E5, _D5, _C5, _B4, _A4 = 659.26, 587.33, 523.25, 493.88, 440.0
KALINKA_QUARTER = 0.18
KALINKA = [(_E5, 2),
           (_D5, 2), (_B4, 1), (_C5, 1),
           (_D5, 2), (_B4, 1), (_C5, 1),
           (_D5, 2), (_C5, 1), (_B4, 1),
           (_A4, 2)]

TRANSLIT = dict(zip("АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя№",
                    ["A", "B", "V", "G", "D", "E", "E", "ZH", "Z", "I", "J", "K", "L", "M", "N", "O", "P",
                     "R", "S", "T", "U", "F", "H", "C", "CH", "SH", "SCH", "", "Y", "", "E", "YU", "YA",
                     "a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "j", "k", "l", "m", "n", "o", "p",
                     "r", "s", "t", "u", "f", "h", "c", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya", "N"]))


def translit(s):
    return "".join(TRANSLIT.get(ch, ch) for ch in s)


def digits(s):
    return "".join(ch for ch in str(s) if ch.isdigit())


# ============================================================================ звук
def lowpass_taps(fs, cutoff, n=127):
    m = np.arange(n) - (n - 1) / 2
    h = np.sinc(2 * cutoff / fs * m) * np.blackman(n)
    return h / h.sum()


class Downsampler:
    """Поток fs_in -> 8000 Гц: ФНЧ 3,4 кГц + прореживание (целый коэффициент) или интерполяция."""

    def __init__(self, fs_in):
        self.fs_in = float(fs_in)
        self.ratio = self.fs_in / RX_FS
        self.taps = lowpass_taps(self.fs_in, 3400.0) if self.ratio > 1.001 else None
        self.hist = np.zeros(0 if self.taps is None else len(self.taps) - 1)
        self.pos = 0.0          # позиция следующего выходного отсчёта во входном потоке
        self.consumed = 0       # сколько входных отсчётов уже отфильтровано

    def push(self, x):
        x = np.asarray(x, dtype=np.float64)
        if self.taps is None:
            return x.astype(np.float32)
        z = np.concatenate((self.hist, x))
        y = np.convolve(z, self.taps, mode="valid")          # len(y) == len(x)
        self.hist = z[-(len(self.taps) - 1):]
        start = self.consumed
        self.consumed += len(y)
        idx = np.arange(self.pos, self.consumed - 1, self.ratio)
        if len(idx) == 0:
            return np.zeros(0, dtype=np.float32)
        self.pos = idx[-1] + self.ratio
        out = np.interp(idx - start, np.arange(len(y)), y)
        return out.astype(np.float32)


def list_devices():
    """[(index, name, max_in, max_out)] — только MME (на Win7 надёжнее всего), иначе все."""
    if sd is None:
        return []
    try:
        devs = sd.query_devices()
        apis = sd.query_hostapis()
    except Exception:
        return []
    mme = None
    for i, a in enumerate(apis):
        if "MME" in a.get("name", ""):
            mme = i
    out = []
    for i, d in enumerate(devs):
        if mme is not None and d.get("hostapi") != mme:
            continue
        out.append((i, d["name"], d["max_input_channels"], d["max_output_channels"]))
    return out


def device_index(name, kind):
    if not name:
        return None
    for i, n, mi, mo in list_devices():
        if n == name and ((kind == "in" and mi > 0) or (kind == "out" and mo > 0)):
            return i
    return None


class Player:
    """Проигрывание буфера на устройстве через собственный OutputStream (не sd.play — его
    один поток на всё приложение, а нам нужны и передача, и звонок одновременно)."""

    def __init__(self):
        self.stream = None
        self.lock = threading.Lock()

    def play(self, data, fs, device, loop=False, done=None, on_chunk=None):
        self.stop()
        data = np.asarray(data, dtype=np.float32)
        state = {"pos": 0, "finished": False}

        def cb(outdata, frames, t, status):
            p = state["pos"]
            if loop:
                idx = (p + np.arange(frames)) % len(data)
                outdata[:, 0] = data[idx]
                state["pos"] = (p + frames) % len(data)
                return
            chunk = data[p:p + frames]
            outdata[:len(chunk), 0] = chunk
            if on_chunk is not None:
                try:
                    on_chunk(chunk)
                except Exception:
                    pass
            outdata[len(chunk):, 0] = 0
            state["pos"] = p + frames
            if p + frames >= len(data):
                raise sd.CallbackStop

        def fin():
            if not state["finished"]:
                state["finished"] = True
                if done:
                    done()

        st = sd.OutputStream(samplerate=fs, device=device, channels=1, dtype="float32",
                             callback=cb, finished_callback=fin, blocksize=1024)
        with self.lock:
            self.stream = st
        st.start()

    def stop(self):
        with self.lock:
            st, self.stream = self.stream, None
        if st is not None:
            try:
                st.abort()
                st.close()
            except Exception:
                pass

    @property
    def active(self):
        st = self.stream
        return st is not None and st.active


def output_rate(device):
    for fs in (48000, 44100):
        try:
            sd.check_output_settings(device=device, samplerate=fs, channels=1, dtype="float32")
            return fs
        except Exception:
            continue
    try:
        return int(sd.query_devices(device if device is not None else sd.default.device[1])["default_samplerate"])
    except Exception:
        return 48000


def answer_pattern(style, fs, volume):
    """Сигнал ответа в эфир: мелодия — один раз без паузы; тоны — 2,5 с, конец плавно гасится."""
    x = ring_pattern(style, fs, volume)
    if style == "kalinka":
        return x[:max(0, len(x) - int(0.8 * fs))]
    n = int(ANSWER_SECONDS * fs)
    y = np.tile(x, n // len(x) + 1)[:n].copy()
    f = min(n, int(0.02 * fs))
    if f:
        y[-f:] *= np.linspace(1, 0, f)
    return y.astype(np.float32)


def ring_pattern(style, fs, volume):
    out = []

    def tone(f, sec):
        n = int(sec * fs)
        t = np.arange(n) / fs
        w = np.ones(n)
        r = max(1, int(0.004 * fs))
        w[:r] = np.linspace(0, 1, r)
        w[-r:] = np.linspace(1, 0, r)
        out.append(volume * w * np.sin(2 * np.pi * f * t))

    def silence(sec):
        out.append(np.zeros(int(sec * fs)))

    if style == "kalinka":
        for f, n in KALINKA:
            dur = n * KALINKA_QUARTER
            m = int((dur - 0.015) * fs)
            t = np.arange(m) / fs
            env = np.minimum(1, t / 0.006) * np.exp(-1.2 * t / dur) * np.minimum(1, (m - 1 - np.arange(m)) / (0.006 * fs))
            out.append(volume * env * (0.85 * np.sin(2 * np.pi * f * t) + 0.15 * np.sin(4 * np.pi * f * t)))
            silence(0.015)
        silence(0.8)
    elif style == "vertex":
        for _ in range(2):
            for _ in range(10):
                tone(1500, 0.025)
                tone(2000, 0.025)
            silence(0.2)
        silence(1.4)
    elif style == "beep":
        for _ in range(3):
            tone(1200, 0.15)
            silence(0.1)
        silence(1.0)
    else:
        for _ in range(5):
            tone(1000, 0.08)
            tone(1300, 0.08)
        silence(1.0)
    return np.concatenate(out).astype(np.float32)


DEFAULT_OUT = "<системный выход>"

# ============================================================================ самоконтроль
class Monitor:
    """Самоконтроль: звук эфира и/или своей передачи одновременно на одно или несколько
    устройств (например, динамики ноутбука при трансивере на внешней звуковой карте).
    Источник подаёт отсчёты 8 кГц; у каждого устройства свой буфер (не больше 0,5 с)."""

    def __init__(self):
        self.outs = {}           # имя -> dict(stream, fs, buf, lock)
        self.level = 0.5
        self.errors = []

    def configure(self, names, level):
        self.level = float(level)
        names = [n for n in names if n]
        for n in list(self.outs):
            if n not in names:
                self._close(n)
        self.errors = []
        if sd is None:
            return
        for n in names:
            if n in self.outs:
                continue
            dev = device_index(n, "out") if n != DEFAULT_OUT else None    # DEFAULT_OUT — системный выход
            if dev is None and n != DEFAULT_OUT:
                self.errors.append("%s: устройство не найдено" % n)
                continue
            for fs in (RX_FS, 48000, 44100):
                o = dict(fs=fs, buf=np.zeros(0, np.float32), lock=threading.Lock())
                try:
                    st = sd.OutputStream(samplerate=fs, device=dev, channels=1, dtype="float32",
                                         blocksize=int(fs // 20), callback=self._cb(o))
                    st.start()
                    o["stream"] = st
                    self.outs[n] = o
                    break
                except Exception as ex:
                    err = ex
            else:
                self.errors.append("%s: %s" % (n, err))

    def _cb(self, o):
        def cb(outdata, frames, t, status):
            with o["lock"]:
                b = o["buf"]
                k = min(frames, len(b))
                outdata[:k, 0] = b[:k] * self.level
                outdata[k:, 0] = 0
                o["buf"] = b[k:]
        return cb

    def feed(self, x8):
        """x8 — отсчёты 8 кГц"""
        if not self.outs or len(x8) == 0:
            return
        x8 = np.asarray(x8, dtype=np.float32)
        for o in list(self.outs.values()):
            y = x8
            if o["fs"] != RX_FS:
                n = int(len(x8) * o["fs"] / RX_FS)
                y = np.interp(np.arange(n) * RX_FS / o["fs"], np.arange(len(x8)), x8).astype(np.float32)
            with o["lock"]:
                b = np.concatenate((o["buf"], y))
                cap = int(0.5 * o["fs"])
                o["buf"] = b[-cap:] if len(b) > cap else b

    def _close(self, n):
        o = self.outs.pop(n, None)
        if o and o.get("stream") is not None:
            try:
                o["stream"].abort()
                o["stream"].close()
            except Exception:
                pass

    def close(self):
        for n in list(self.outs):
            self._close(n)


def to_8k(x, fs):
    x = np.asarray(x, dtype=np.float32)
    if fs == RX_FS or len(x) == 0:
        return x
    n = int(len(x) * RX_FS / fs)
    return np.interp(np.arange(n) * fs / RX_FS, np.arange(len(x)), x).astype(np.float32)


# ============================================================================ внешнее устройство
EXT_LINES = ["RTS", "DTR", "RTS+DTR"]


class ExtControl:
    """Внешнее устройство (сирена, лампа, реле): «1» на линии RTS/DTR отдельного COM-порта."""

    def __init__(self):
        self.ser = None
        self.port = ""
        self.on = False
        self.lock = threading.Lock()

    def _open(self, port, line, invert):
        if self.ser is not None and self.port == port:
            return
        self._close_locked(line, invert)
        if serial is None:
            raise RuntimeError("pyserial недоступен: %s" % SERIAL_ERROR)
        if not port:
            raise RuntimeError("не выбран COM-порт внешнего устройства")
        s = serial.Serial()
        s.port = port
        s.baudrate = 9600
        s.rts = bool(invert) if line in ("RTS", "RTS+DTR") else False   # исходный уровень до open()
        s.dtr = bool(invert) if line in ("DTR", "RTS+DTR") else False
        s.open()
        self.ser, self.port = s, port

    def set(self, on, port, line, invert):
        """возвращает текст ошибки или None"""
        with self.lock:
            try:
                self._open(port, line, invert)
                level = bool(on) != bool(invert)
                if line in ("RTS", "RTS+DTR"):
                    self.ser.rts = level
                if line in ("DTR", "RTS+DTR"):
                    self.ser.dtr = level
                self.on = bool(on)
                return None
            except Exception as ex:
                self.on = False
                return "Внешнее устройство: %s" % ex

    def _close_locked(self, line, invert):
        if self.ser is not None:
            try:
                if line in ("RTS", "RTS+DTR"):
                    self.ser.rts = bool(invert)
                if line in ("DTR", "RTS+DTR"):
                    self.ser.dtr = bool(invert)
                self.ser.close()
            except Exception:
                pass
        self.ser, self.port, self.on = None, "", False

    def close(self, line="RTS+DTR", invert=False):
        with self.lock:
            self._close_locked(line, invert)


# ============================================================================ ядро
class Core:
    """Настройки, приём, передача, PTT, звонок. С GUI общается через очередь событий."""

    def __init__(self, ui_queue):
        self.q = ui_queue
        self.s = dict(DEFAULTS)
        self.load()
        self.rx = S.StreamReceiver(RX_FS)
        self.audio_q = queue.Queue()
        self.stream = None
        self.down = None
        self.rx_thread = None
        self.receiving = False
        self.rx_start = time.time()
        self.level = 0.0
        self.active_channel = 1
        self.in_channels = 1
        self.ch_energy = None
        self.mute_until = 0.0
        self.tx_player = Player()
        self.ring_players = []
        self.ring_timer = None
        self.ptt = PTT.PttController()
        self.monitor = Monitor()
        self.ext = ExtControl()
        self.ext_manual = False
        self.ext_timer = None
        self.listening = False
        self.listen_manual = False
        self.listen_timer = None
        self.listen_pending = False
        self.tx_queue = []
        self.transmitting = False
        self.watchdog = None

    # ---- настройки
    def load(self):
        try:
            with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
                self.s.update(json.load(f))
        except Exception:
            pass
        old = self.s.pop("ptt_mode", None)          # настройки версии 0.3-dev
        if old in ("rts", "dtr", "both"):
            self.s["ptt_method"] = {"rts": "RTS", "dtr": "DTR", "both": "RTS+DTR"}[old]
        rd = self.s.pop("ring_dev", None)
        if rd and not self.s.get("mon_devs"):
            self.s["mon_devs"] = [rd]
        if self.s.get("ptt_method") not in PTT.METHODS:
            self.s["ptt_method"] = "none"

    def save(self):
        try:
            with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
                json.dump(self.s, f, ensure_ascii=False, indent=1)
        except Exception:
            pass

    def journal(self, line):
        try:
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except Exception:
            pass

    # ---- приём
    def start_rx(self):
        if sd is None:
            raise RuntimeError("звуковая библиотека недоступна: %s" % SD_ERROR)
        self.stop_rx()
        dev = device_index(self.s["in_dev"], "in")
        try:
            maxin = int(sd.query_devices(dev if dev is not None else sd.default.device[0])["max_input_channels"])
        except Exception:
            maxin = 1
        # открываем до 2 каналов и берём ОДИН (не среднее): у стерео-интерфейса трансивер обычно на одном
        # входе, а сведение в моно с пустым каналом занижало сигнал вдвое
        nch = 2 if maxin >= 2 else 1
        last = None
        for fs, ch in ((RX_FS, nch), (48000, nch), (44100, nch), (RX_FS, 1), (48000, 1)):
            try:
                st = sd.InputStream(samplerate=fs, device=dev, channels=ch, dtype="float32",
                                    blocksize=int(fs // 10), callback=self._on_audio)
                self.in_channels = ch
                self.ch_energy = np.zeros(ch)
                self.down = Downsampler(fs)
                st.start()
                self.stream = st
                break
            except Exception as ex:
                last = ex
        if self.stream is None:
            raise RuntimeError("не удалось открыть вход: %s" % last)
        self.audio_q = queue.Queue()
        self.rx.reset()
        self.rx_start = time.time()
        self.receiving = True
        self.rx_thread = threading.Thread(target=self._rx_loop, daemon=True)
        self.rx_thread.start()
        return int(self.stream.samplerate)

    def stop_rx(self):
        self.receiving = False
        st, self.stream = self.stream, None
        if st is not None:
            try:
                st.abort()
                st.close()
            except Exception:
                pass
        self.level = 0.0

    def _on_audio(self, indata, frames, t, status):
        nch = indata.shape[1]
        want = int(self.s.get("in_channel") or 0)
        if want > 0:
            sel = min(want, nch) - 1
        elif nch > 1:
            e = np.mean(indata[::4].astype(np.float64) ** 2, axis=0)
            if self.ch_energy is None or len(self.ch_energy) != nch:
                self.ch_energy = np.zeros(nch)
            self.ch_energy = self.ch_energy * 0.9 + e
            best = int(np.argmax(self.ch_energy))
            cur = self.active_channel - 1
            sel = cur if (cur < nch and self.ch_energy[cur] * 2 >= self.ch_energy[best]) else best
        else:
            sel = 0
        self.active_channel = sel + 1
        x = indata[:, sel]
        peak = float(np.max(np.abs(x))) if len(x) else 0.0
        self.level = max(peak, self.level * 0.8)      # пиковый индикатор: быстрый подъём, плавный спад
        y = self.down.push(x)
        if time.time() < self.mute_until:
            y = np.zeros_like(y)
        self.audio_q.put_nowait(y)       # аудиопоток не ждёт декодер
        if self.s["mon_rx"] or self.listening:
            self.monitor.feed(y)

    def _rx_loop(self):
        while self.receiving:
            time.sleep(1.0)
            if not self.receiving:
                break
            try:
                while True:
                    try:
                        self.rx.append(self.audio_q.get_nowait())
                    except queue.Empty:
                        break
                self.rx.fixed_center = None if self.s["afc"] else float(self.s["fixed_center"])
                calls = self.rx.process()
                self.q.put(("centers", list(self.rx.last_centers)))
                for c in calls:
                    self.q.put(("rx", c, self.rx_start + c["time"], False))
            except Exception as ex:
                self.q.put(("error", "Ошибка декодера: %s" % ex))

    # ---- PTT / CAT (логика из HFP)
    def ptt_cfg(self):
        s = self.s
        try:
            addr = PTT.parse_hex_addr(s["ptt_icom_addr"])
        except Exception:
            addr = 0x94
        return dict(method=s["ptt_method"], port=s["ptt_port"], baud=int(s["ptt_baud"] or 9600),
                    invert=bool(s["ptt_invert"]), icom_addr=addr, kenwood_variant=s["ptt_kenwood"])

    def reopen_ptt(self):
        """(пере)открыть порт по настройкам; возвращает текст ошибки или None"""
        return self.ptt.configure(self.ptt_cfg())

    def key(self, on):
        if on:
            return self.ptt.key(True)
        return self.ptt.unkey_safe()

    # ---- внешнее устройство
    def ext_conflict(self):
        p = self.s.get("ext_port") or ""
        return bool(p) and self.s["ptt_method"] != "none" and p == self.s["ptt_port"]

    def _ext_set(self, on):
        if on and self.ext_conflict():
            self.q.put(("error", "Внешнее устройство: порт %s занят PTT/CAT — выберите другой COM-порт"
                        % self.s["ext_port"]))
            return False
        err = self.ext.set(on, self.s.get("ext_port") or "", self.s.get("ext_line") or "DTR",
                           bool(self.s.get("ext_invert")))
        if err:
            self.q.put(("error", err))
            return False
        return True

    def ext_pulse(self, seconds=None):
        """«1» на линии на заданное время (1…60 с); ручное включение не перебивается."""
        if self.ext_manual or not self._ext_set(True):
            return
        if self.ext_timer is not None:
            self.ext_timer.cancel()
        sec = min(60.0, max(1.0, float(seconds or self.s.get("ext_seconds") or 5)))

        def off():
            if not self.ext_manual:
                self._ext_set(False)
        self.ext_timer = threading.Timer(sec, off)
        self.ext_timer.daemon = True
        self.ext_timer.start()

    def ext_toggle(self):
        """кнопка на панели: принудительно включить / выключить"""
        if self.ext_timer is not None:
            self.ext_timer.cancel()
            self.ext_timer = None
        if self.ext.on:
            self.ext_manual = False
            self._ext_set(False)
        elif self._ext_set(True):
            self.ext_manual = True

    def ext_reset(self):
        if self.ext_timer is not None:
            self.ext_timer.cancel()
            self.ext_timer = None
        self.ext_manual = False
        self.ext.close(self.s.get("ext_line") or "RTS+DTR", bool(self.s.get("ext_invert")))

    # ---- прослушивание эфира после вызова (чтобы услышать голосовое сообщение)
    def _set_listening(self, on):
        if self.listening == on:
            return
        self.listening = on
        for e in self.apply_monitor():
            self.q.put(("error", "Самоконтроль: %s" % e))

    def start_listen(self, seconds=None):
        """открыть вход на заданное время (5 с … 10 мин); ручное включение не перебивается"""
        if self.listen_manual:
            return
        self.stop_ring()                    # звонок отработал — слушаем вызывающего
        if not self.receiving:
            self.q.put(("error", "Прослушивание: приём выключен — нажмите «Приём»"))
        self._set_listening(True)
        if self.listen_timer is not None:
            self.listen_timer.cancel()
        sec = min(600.0, max(5.0, float(seconds or self.s.get("listen_seconds") or 60)))
        self.q.put(("info", "Прослушивание эфира включено на %.0f с" % sec))

        def off():
            if not self.listen_manual:
                self.q.put(("listen_off",))
        self.listen_timer = threading.Timer(sec, off)
        self.listen_timer.daemon = True
        self.listen_timer.start()

    def toggle_listen(self):
        if self.listen_timer is not None:
            self.listen_timer.cancel()
            self.listen_timer = None
        self.listen_pending = False
        if self.listening:
            self.listen_manual = False
            self._set_listening(False)
        else:
            self.stop_ring()
            self.listen_manual = True
            self._set_listening(True)

    # ---- самоконтроль
    def apply_monitor(self):
        devs = list(self.s.get("mon_devs") or [])
        active = devs if (self.s["mon_rx"] or self.s["mon_tx"] or self.listening) else []
        if self.listening and not active:
            active = [DEFAULT_OUT]          # нет устройств самоконтроля — системный выход
        self.monitor.configure(active, self.s["mon_level"])
        return self.monitor.errors

    # ---- передача
    def build(self, to_id, message, fs):
        text = None
        if message:
            text = translit(message) if self.s["translit"] else message
            text = text[:MAX_MSG]
        stream = S.build_call(digits(to_id), digits(self.s["my_id"]), text)
        y = S.modulate(stream, fs, float(self.s["dot_seconds"]), S.F_CENTER, float(self.s["tx_level"]))
        return text or "", y

    def send(self, to_id, message, title):
        if sd is None:
            return "Звуковая библиотека недоступна: %s" % SD_ERROR
        to, me = digits(to_id), digits(self.s["my_id"])
        if not to or not me or len(to) > 10 or len(me) > 10:
            return "Укажите цифровые ID: свой и получателя (4 или 6 цифр)"
        dev = device_index(self.s["out_dev"], "out")
        fs = output_rate(dev)
        text, y = self.build(to, message, fs)
        lead = np.zeros(int(float(self.s["ptt_delay"]) * fs), dtype=np.float32)
        tail = np.zeros(int(float(self.s["ptt_tail"]) * fs), dtype=np.float32)
        audio = np.concatenate((lead, y, tail))
        self.tx_queue.append((audio, fs, dev, me, to, text, title))
        if not self.transmitting:
            self._play_next()
        return None

    def send_ring(self, to_id):
        """Ответ в эфир: сигнал ответа (отдельный от звонка) звучит один раз —
        мелодия целиком (~2,9 с) или тоны 2,5 с; передача = задержка PTT + сигнал + хвост."""
        if sd is None:
            return "Звуковая библиотека недоступна: %s" % SD_ERROR
        dev = device_index(self.s["out_dev"], "out")
        fs = output_rate(dev)
        sig = answer_pattern(self.s.get("answer_style", "kalinka"), fs, float(self.s["tx_level"]))
        nl = int(float(self.s["ptt_delay"]) * fs)
        nt = int(float(self.s["ptt_tail"]) * fs)
        audio = np.concatenate((np.zeros(nl), sig, np.zeros(nt))).astype(np.float32)
        self.tx_queue.append((audio, fs, dev, digits(self.s["my_id"]), digits(to_id), "", "Ответ в эфир"))
        if not self.transmitting:
            self._play_next()
        return None

    def _play_next(self):
        if not self.tx_queue:
            self._finish_tx()
            return
        audio, fs, dev, me, to, text, title = self.tx_queue.pop(0)
        dur = len(audio) / fs
        self.transmitting = True
        if self.s["mute_rx_on_tx"]:
            self.mute_until = time.time() + dur + 1.0
        err = self.key(True)
        if err:
            self.q.put(("error", "%s — передача отменена" % err))
            self.tx_queue = []
            self._finish_tx()
            return
        self.q.put(("tx", me, to, text, title, dur))
        if self.watchdog is not None:
            self.watchdog.cancel()
        self.watchdog = threading.Timer(dur + 5.0, self._watchdog_fire)
        self.watchdog.daemon = True
        self.watchdog.start()
        try:
            mon = (lambda ch, f=fs: self.monitor.feed(to_8k(ch, f))) if self.s["mon_tx"] else None
            self.tx_player.play(audio, fs, dev, done=lambda: self.q.put(("tx_done",)), on_chunk=mon)
        except Exception as ex:
            self.q.put(("error", "Ошибка передачи: %s" % ex))
            self.stop_tx()

    def tx_done(self):
        if self.transmitting:
            self._play_next()

    def _watchdog_fire(self):
        if self.transmitting:
            self.q.put(("error", "Передача не завершилась вовремя — PTT снят принудительно"))
            self.q.put(("stop_tx",))

    def _finish_tx(self):
        if self.watchdog is not None:
            self.watchdog.cancel()
            self.watchdog = None
        if getattr(self, "listen_pending", False):
            self.listen_pending = False
            t = threading.Timer(0.5, lambda: self.q.put(("listen_start",)))   # после размьючивания входа
            t.daemon = True
            t.start()
        self.key(False)
        self.transmitting = False
        if self.s["mute_rx_on_tx"]:
            self.mute_until = time.time() + 0.5

    def stop_tx(self):
        self.tx_queue = []
        self.tx_player.stop()
        self._finish_tx()
        self.mute_until = 0.0

    def test_ptt(self):
        if self.transmitting:
            return
        if self.s["ptt_method"] == "none":
            self.q.put(("info", "PTT не управляется (VOX / внешний PTT): проверять нечего"))
            return
        err = self.reopen_ptt() or self.key(True)
        if err:
            self.q.put(("error", err))
            return
        self.q.put(("info", "Тест PTT: %s, %s — 1 с (лучше на эквивалент нагрузки)" %
                    (PTT_TITLES.get(self.s["ptt_method"]), self.s["ptt_port"])))

        def off():
            if not self.transmitting:
                self.key(False)
        t = threading.Timer(1.0, off)
        t.daemon = True
        t.start()

    # ---- звонок
    def ring(self, seconds=None, answer=False):
        """Звонок по кругу; answer=True — один раз проиграть сигнал ответа (прослушивание, не в эфир)."""
        if sd is None:
            return
        self.stop_ring()
        names = [n for n in (self.s.get("mon_devs") or []) if n] or [""]
        for n in names:
            dev = device_index(n, "out") if n else None
            fs = output_rate(dev)
            if answer:
                pat = answer_pattern(self.s.get("answer_style", "kalinka"), fs, float(self.s["ring_volume"]))
            else:
                pat = ring_pattern(self.s["ring_style"], fs, float(self.s["ring_volume"]))
            pl = Player()
            try:
                pl.play(pat, fs, dev, loop=not answer)
                self.ring_players.append(pl)
            except Exception as ex:
                self.q.put(("error", "Звонок (%s): %s" % (n or "системный выход", ex)))
        self.ring_timer = threading.Timer(float(seconds or self.s["ring_seconds"]), self.stop_ring)
        self.ring_timer.daemon = True
        self.ring_timer.start()

    def stop_ring(self):
        if self.ring_timer is not None:
            self.ring_timer.cancel()
            self.ring_timer = None
        for pl in self.ring_players:
            pl.stop()
        self.ring_players = []

    # ---- файлы
    def save_wav(self, path, to_id, message):
        text, y = self.build(to_id, message, 48000)
        S.write_wav(path, y, 48000)

    def decode_file(self, path):
        x, fs = S.read_wav(path)
        if fs != RX_FS:
            d = Downsampler(fs)
            x = d.push(x)
        center = None if self.s["afc"] else float(self.s["fixed_center"])
        return S.decode(x, RX_FS, center)

    def shutdown(self):
        try:
            self.stop_tx()
        except Exception:
            pass
        self.ptt.close()
        self.ext_reset()
        self.stop_ring()
        self.stop_rx()
        self.monitor.close()
        self.save()


# ============================================================================ GUI
COLORS = dict(rx="#1b7f2a", rx_bad="#c06000", tx="#1f4fbf", info="#666666", error="#c00000",
              mine="#0a5c1a")


class App:
    def __init__(self, root):
        self.root = root
        self.q = queue.Queue()
        self.core = Core(self.q)
        s = self.core.s
        root.title("%s %s" % (APP_NAME, VERSION))
        root.geometry("940x620")
        root.minsize(760, 480)
        try:
            root.iconname(APP_NAME)
        except Exception:
            pass
        self.font_mono = ("Consolas", 10) if sys.platform.startswith("win") else ("Menlo", 11)

        self.v = dict(
            my_id=tk.StringVar(value=s["my_id"]), to_id=tk.StringVar(value=s["to_id"]),
            in_dev=tk.StringVar(value=s["in_dev"] or "По умолчанию"),
            out_dev=tk.StringVar(value=s["out_dev"] or "По умолчанию"),
            msg=tk.StringVar(), status=tk.StringVar(value="Готово"), afc=tk.StringVar(value="АПЧ —"),
        )
        self.incoming = None
        self._build()
        self.refresh_devices()
        err = self.core.reopen_ptt()
        if err:
            self.add("PTT: %s" % err, "error")
        for e in self.core.apply_monitor():
            self.add("Самоконтроль: %s" % e, "error")
        root.protocol("WM_DELETE_WINDOW", self.on_close)
        if sd is None:
            self.add("Звуковая библиотека недоступна: %s" % SD_ERROR, "error")
        self.add("Нажмите «Приём», чтобы слушать эфир, или откройте запись (Ctrl+O). "
                 "Передача в эфир на КВ требует лицензии.", "info")
        root.after(100, self.poll)

    # ---- построение окна
    def _build(self):
        root = self.root
        # верхняя панель: ID | вход и выход друг под другом | индикаторы и кнопки в два ряда
        # (поля выбора устройств растягиваются и не пропадают в узком окне)
        top = ttk.Frame(root, padding=(8, 6))
        top.pack(fill="x")
        idf = ttk.Frame(top)
        idf.grid(row=0, column=0, rowspan=2, sticky="w", padx=(0, 12))
        ttk.Label(idf, text="Мой ID").pack(anchor="w")
        e = ttk.Entry(idf, textvariable=self.v["my_id"], width=9, font=self.font_mono)
        e.pack(anchor="w")
        e.bind("<FocusOut>", lambda ev: self.store("my_id", digits(self.v["my_id"].get())))
        ttk.Label(top, text="Вход").grid(row=0, column=1, sticky="e", padx=(0, 4), pady=2)
        self.cb_in = ttk.Combobox(top, textvariable=self.v["in_dev"], width=30, state="readonly")
        self.cb_in.grid(row=0, column=2, sticky="ew", pady=2)
        self.cb_in.bind("<<ComboboxSelected>>", lambda ev: self.on_dev("in_dev", self.v["in_dev"].get()))
        ttk.Button(top, text="↻", width=3, command=self.refresh_devices).grid(row=0, column=3, padx=4)
        ttk.Label(top, text="Выход").grid(row=1, column=1, sticky="e", padx=(0, 4), pady=2)
        self.cb_out = ttk.Combobox(top, textvariable=self.v["out_dev"], width=30, state="readonly")
        self.cb_out.grid(row=1, column=2, sticky="ew", pady=2)
        self.cb_out.bind("<<ComboboxSelected>>", lambda ev: self.on_dev("out_dev", self.v["out_dev"].get()))
        top.columnconfigure(2, weight=1, minsize=160)

        # правая колонка, ряд 1: индикатор уровня, канал, АПЧ
        r1 = ttk.Frame(top)
        r1.grid(row=0, column=4, sticky="e", padx=(12, 0))
        self.meter = tk.Canvas(r1, width=110, height=12, highlightthickness=1, highlightbackground="#999")
        self.meter.pack(side="left", padx=4)
        self.meter_bar = self.meter.create_rectangle(0, 0, 0, 12, fill="#3a3", width=0)
        for m in (-40, -20, -12, -6, -3):             # риски шкалы дБFS
            x = 110 * (m + 60) / 60.0
            self.meter.create_line(x, 0, x, 12, fill="#777")
        self.db_lbl = ttk.Label(r1, text="  —  дБ", width=8, font=self.font_mono)
        self.db_lbl.pack(side="left")
        self.ch_lbl = ttk.Label(r1, text="", width=6)
        self.ch_lbl.pack(side="left")
        ttk.Label(r1, textvariable=self.v["afc"], width=14, font=self.font_mono).pack(side="left", padx=4)

        # ряд 2: TX, Слушать, Внешн., Приём, Настройки
        r2 = ttk.Frame(top)
        r2.grid(row=1, column=4, sticky="e", padx=(12, 0))
        lamp = tk.Canvas(r2, width=40, height=14, highlightthickness=0)
        lamp.pack(side="left", padx=4)
        self.lamp = lamp.create_oval(2, 2, 12, 12, fill="#bbb", outline="")
        lamp.create_text(26, 7, text="TX", font=("Segoe UI", 8, "bold"))
        self.lamp_canvas = lamp
        ls_c = tk.Canvas(r2, width=14, height=14, highlightthickness=0)
        ls_c.pack(side="left")
        self.listen_lamp = ls_c.create_oval(2, 2, 12, 12, fill="#bbb", outline="")
        self.listen_canvas = ls_c
        self.btn_listen = ttk.Button(r2, text="Слушать", width=9, command=self.core.toggle_listen)
        self.btn_listen.pack(side="left", padx=2)
        ext_c = tk.Canvas(r2, width=14, height=14, highlightthickness=0)
        ext_c.pack(side="left")
        self.ext_lamp = ext_c.create_oval(2, 2, 12, 12, fill="#bbb", outline="")
        self.ext_canvas = ext_c
        self.btn_ext = ttk.Button(r2, text="Внешн.", width=11, command=self.ext_toggle)
        self.btn_ext.pack(side="left", padx=2)
        self.btn_rx = ttk.Button(r2, text="Приём", command=self.toggle_rx)
        self.btn_rx.pack(side="left", padx=2)
        ttk.Button(r2, text="Настройки", command=self.open_settings).pack(side="left", padx=2)

        self.banner = tk.Frame(root, bg="#ffe2b8")
        self.banner_lbl = tk.Label(self.banner, bg="#ffe2b8", font=("Segoe UI", 11, "bold"), anchor="w",
                                   justify="left")
        self.banner_lbl.pack(side="left", fill="x", expand=True, padx=10, pady=6)
        ttk.Button(self.banner, text="Сбросить", command=self.dismiss_ring).pack(side="right", padx=6)
        ttk.Button(self.banner, text="Ответить", command=self.answer_ring).pack(side="right")

        mid = ttk.Frame(root)
        mid.pack(fill="both", expand=True)
        self.mid = mid
        self.text = tk.Text(mid, wrap="word", state="disabled", font=self.font_mono, padx=6, pady=4)
        sb = ttk.Scrollbar(mid, command=self.text.yview)
        self.text.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        self.text.pack(side="left", fill="both", expand=True)
        for k, c in COLORS.items():
            self.text.tag_configure(k, foreground=c)
        self.text.tag_configure("detail", foreground="#888888")
        self.text.tag_configure("bold", font=self.font_mono + ("bold",))
        self.text.bind("<Double-Button-1>", self.on_log_double)

        bot = ttk.Frame(root, padding=(8, 6))
        bot.pack(fill="x")
        row1 = ttk.Frame(bot)
        row1.pack(fill="x")
        ttk.Label(row1, text="Кому").pack(side="left")
        ttk.Entry(row1, textvariable=self.v["to_id"], width=9, font=self.font_mono).pack(side="left", padx=(4, 8))
        ttk.Button(row1, text="Вызов", command=self.send_call).pack(side="left")
        self.tx_lbl = ttk.Label(row1, textvariable=self.v["status"])
        self.tx_lbl.pack(side="left", padx=12)
        ttk.Button(row1, text="Декодировать WAV…", command=self.open_wav).pack(side="right")
        ttk.Button(row1, text="Сохранить в WAV…", command=self.save_wav).pack(side="right", padx=4)
        self.btn_abort = ttk.Button(row1, text="Прервать передачу", command=self.stop_tx)
        row2 = ttk.Frame(bot)
        row2.pack(fill="x", pady=(6, 0))
        ent = ttk.Entry(row2, textvariable=self.v["msg"])
        ent.pack(side="left", fill="x", expand=True)
        ent.bind("<Return>", lambda ev: self.send_msg())
        self.cnt = ttk.Label(row2, text="0/%d" % MAX_MSG, width=7)
        self.cnt.pack(side="left", padx=6)
        ttk.Button(row2, text="Отправить", command=self.send_msg).pack(side="left")
        self.v["msg"].trace_add("write", lambda *a: self.cnt.configure(
            text="%d/%d" % (min(len(self.v["msg"].get()), MAX_MSG), MAX_MSG)))
        self.root.bind("<Control-o>", lambda ev: self.open_wav())
        self.root.bind("<Escape>", lambda ev: self.dismiss_ring())

    def ext_toggle(self):
        if not self.core.s.get("ext_port"):
            self.add("Внешнее устройство: укажите COM-порт в настройках", "error")
            return
        self.core.ext_toggle()

    # ---- журнал
    def add(self, text, tag="info", detail=None, sender=None):
        now = datetime.datetime.now().strftime("%d.%m %H:%M:%S")
        self.text.configure(state="normal")
        start = self.text.index("end-1c")
        self.text.insert("end", "[%s] " % now, "detail")
        self.text.insert("end", text + "\n", tag)
        if detail:
            self.text.insert("end", "            " + detail + "\n", "detail")
        if sender:
            self.text.tag_add("from:" + sender, start, "end-1c")
        self.text.configure(state="disabled")
        self.text.see("end")
        self.core.journal("[%s] %s%s" % (now, text, (" | " + detail) if detail else ""))

    def on_log_double(self, ev):
        idx = self.text.index("@%d,%d" % (ev.x, ev.y))
        for t in self.text.tag_names(idx):
            if t.startswith("from:"):
                self.v["to_id"].set(t[5:])
                self.store("to_id", t[5:])
                return "break"

    # ---- устройства
    def refresh_devices(self):
        devs = list_devices()
        ins = ["По умолчанию"] + [n for _, n, mi, _ in devs if mi > 0]
        outs = ["По умолчанию"] + [n for _, n, _, mo in devs if mo > 0]
        self.cb_in["values"] = ins
        self.cb_out["values"] = outs
        self.dev_out_names = outs

    def on_dev(self, key, name):
        self.store(key, "" if name == "По умолчанию" else name)
        if key == "in_dev" and self.core.receiving:
            self.toggle_rx()
            self.toggle_rx()

    def store(self, key, val):
        self.core.s[key] = val
        self.core.save()

    # ---- приём
    def toggle_rx(self):
        if self.core.receiving:
            self.core.stop_rx()
            self.btn_rx.configure(text="Приём")
            self.add("Приём остановлен")
            return
        try:
            fs = self.core.start_rx()
            self.btn_rx.configure(text="Стоп приём")
            self.add("Приём запущен (вход %d Гц)" % fs)
        except Exception as ex:
            self.add("Не удалось запустить приём: %s" % ex, "error")

    def handle_rx(self, c, when, from_file):
        me = digits(self.core.s["my_id"])
        mine = c["to"] == me.zfill(len(c["to"]))
        own = (not from_file) and c["from"] == me.zfill(len(c["from"]))
        if not self.core.s["show_all"] and not mine and not from_file:
            return
        if c["eos"] == "ACK-BQ":
            title = "Подтверждение"
        elif c["message"]:
            title = "Сообщение"
        else:
            title = "Вызов"
        if own:
            title = "Своя передача (эхо)"
        else:
            title += (" мне" if mine else "") + (" (файл)" if from_file else "")
        line = "▼ %s  %s → %s" % (title, c["from"], c["to"])
        if c["message"]:
            line += "  «%s»" % c["message"]
        detail = "fmt %s · cat %s · %s · ECC %s · %s · %.1f Гц%s%s" % (
            c["format"], c["category"], c["eos"], c["ecc"], "принят" if c["ecc_ok"] else "СОМНИТЕЛЬНО",
            c["center_hz"], " · LSB" if c["polarity"] == "inverted" else "",
            (" · исправлено %d" % c["dx_rx_conflicts"]) if c["dx_rx_conflicts"] else "")
        tag = ("mine" if mine else "rx") if c["ecc_ok"] else "rx_bad"
        self.add(line, tag, detail, sender=c["from"])
        if mine and not own and not from_file and c["ecc_ok"] and c["eos"] != "ACK-BQ":
            self.show_incoming(title, c)

    # ---- звонок
    def show_incoming(self, title, c):
        self.incoming = c
        txt = "☎  %s от %s" % (title, c["from"])
        if c["message"]:
            txt += ":  " + c["message"]
        self.banner_lbl.configure(text=txt)
        self.banner.pack(fill="x", before=self.mid)
        try:
            self.root.deiconify()
            self.root.lift()
            if sys.platform.startswith("win"):
                import ctypes
                ctypes.windll.user32.FlashWindow(int(self.root.wm_frame(), 16), True)
        except Exception:
            pass
        if self.core.s["ring"]:
            self.core.ring()
        if self.core.s.get("ext_enabled") and self.core.s.get("ext_port"):
            self.core.ext_pulse()
        if self.core.s.get("listen_after_call", True):
            if self.core.s.get("ring_air"):
                self.core.listen_pending = True      # после ответа в эфир
            else:
                self.core.start_listen()
        if self.core.s.get("ring_air"):
            # небольшая пауза: вызывающая станция успевает перейти на приём
            frm = c["from"]

            def air():
                err = self.core.send_ring(frm)
                if err:
                    self.add(err, "error")
            self.root.after(1000, air)

    def answer_ring(self):
        if self.incoming:
            self.v["to_id"].set(self.incoming["from"])
            self.store("to_id", self.incoming["from"])
        self.dismiss_ring()

    def dismiss_ring(self):
        self.core.stop_ring()
        self.incoming = None
        self.banner.pack_forget()

    # ---- передача
    def send_call(self):
        self._send(None, "Вызов")

    def send_msg(self):
        m = self.v["msg"].get().strip()
        if not m:
            return
        if self._send(m, "Сообщение"):
            self.v["msg"].set("")

    def _send(self, msg, title):
        self.store("to_id", digits(self.v["to_id"].get()))
        self.store("my_id", digits(self.v["my_id"].get()))
        err = self.core.send(self.v["to_id"].get(), msg, title)
        if err:
            self.add(err, "error")
            return False
        return True

    def stop_tx(self):
        self.core.stop_tx()
        self.add("Передача прервана", "info")

    # ---- файлы
    def save_wav(self):
        to = digits(self.v["to_id"].get())
        if not to:
            self.add("Укажите получателя", "error")
            return
        p = filedialog.asksaveasfilename(defaultextension=".wav", filetypes=[("WAV", "*.wav")],
                                         initialfile="selcall_%s_to_%s.wav" % (digits(self.core.s["my_id"]), to))
        if not p:
            return
        try:
            self.core.save_wav(p, to, self.v["msg"].get().strip() or None)
            self.add("Сохранено: %s" % os.path.basename(p))
        except Exception as ex:
            self.add("Ошибка записи WAV: %s" % ex, "error")

    def open_wav(self):
        paths = filedialog.askopenfilenames(filetypes=[("WAV", "*.wav"), ("Все файлы", "*.*")])
        for p in paths:
            self.add("Декодирую %s…" % os.path.basename(p))

            def work(path=p):
                try:
                    calls = self.core.decode_file(path)
                    if not calls:
                        self.q.put(("info", "%s: вызовов не найдено" % os.path.basename(path)))
                    for c in calls:
                        self.q.put(("rx", c, time.time(), True))
                except Exception as ex:
                    self.q.put(("error", "%s: %s" % (os.path.basename(path), ex)))
            threading.Thread(target=work, daemon=True).start()

    # ---- цикл событий
    def poll(self):
        try:
            while True:
                ev = self.q.get_nowait()
                k = ev[0]
                if k == "rx":
                    self.handle_rx(ev[1], ev[2], ev[3])
                elif k == "centers":
                    if self.core.s["afc"] and ev[1]:
                        self.v["afc"].set("АПЧ %.1f Гц" % ev[1][0])
                elif k == "tx":
                    _, me, to, text, title, dur = ev
                    line = "▲ %s  %s → %s" % (title, me, to) + (("  «%s»" % text) if text else "")
                    self.add(line, "tx", ("%.1f с · ACK-RQ" % dur) if title in ("Вызов", "Сообщение") else ("%.1f с" % dur))
                    self.v["status"].set("Передача…")
                    self.btn_abort.pack(side="left")
                elif k == "tx_done":
                    self.core.tx_done()
                elif k == "stop_tx":
                    self.core.stop_tx()
                elif k == "listen_start":
                    self.core.start_listen()
                elif k == "listen_off":
                    if not self.core.listen_manual:
                        self.core._set_listening(False)
                elif k == "info":
                    self.add(ev[1], "info")
                elif k == "error":
                    self.add(ev[1], "error")
        except queue.Empty:
            pass
        if not self.core.transmitting and self.v["status"].get() != "Готово":
            self.v["status"].set("Готово")
            self.btn_abort.pack_forget()
        if not self.core.s["afc"]:
            self.v["afc"].set("f0 %.0f Гц" % float(self.core.s["fixed_center"]))
        elif not self.core.receiving:
            self.v["afc"].set("АПЧ —")
        if self.core.receiving and self.core.in_channels > 1:
            self.ch_lbl.configure(text="кан. %d" % self.core.active_channel)
        else:
            self.ch_lbl.configure(text="")
        if not self.core.receiving:
            self.core.level *= 0.8
        lv = min(1.0, self.core.level)
        db = 20 * np.log10(lv) if lv > 1e-6 else -60.0
        db = max(-60.0, db)
        self.meter.coords(self.meter_bar, 0, 0, 110 * (db + 60) / 60.0, 12)
        self.meter.itemconfigure(self.meter_bar, fill="#d00" if db > -3 else ("#db0" if db > -12 else "#3a3"))
        self.meter.tag_raise("all")
        self.meter.tag_lower(self.meter_bar)
        self.db_lbl.configure(text=("%5.1f дБ" % db) if db > -60 else "  —  дБ")
        self.ext_canvas.itemconfigure(self.ext_lamp, fill="#f80" if self.core.ext.on else "#bbb")
        self.listen_canvas.itemconfigure(self.listen_lamp, fill="#2b2" if self.core.listening else "#bbb")
        self.btn_listen.configure(text="Слушаю" if self.core.listen_manual else "Слушать")
        self.btn_ext.configure(text="Внешн. ВКЛ" if self.core.ext_manual else "Внешн.")
        on = self.core.transmitting or self.core.ptt.keyed
        self.lamp_canvas.itemconfigure(self.lamp, fill="#e00" if on else "#bbb")
        self.root.after(100, self.poll)

    # ---- настройки
    def open_settings(self):
        SettingsWindow(self)

    def on_close(self):
        self.core.shutdown()
        self.root.destroy()


class SettingsWindow:
    def __init__(self, app):
        self.app = app
        c = app.core
        s = c.s
        w = tk.Toplevel(app.root)
        w.title("Настройки")
        w.transient(app.root)
        w.resizable(False, False)
        self.w = w
        pad = dict(padx=8, pady=3, sticky="w")
        self.v = dict(
            dot=tk.DoubleVar(value=s["dot_seconds"]), level=tk.DoubleVar(value=s["tx_level"]),
            translit=tk.BooleanVar(value=s["translit"]),
            ptt_method=tk.StringVar(value=PTT_TITLES.get(s["ptt_method"], PTT_TITLES["none"])),
            ptt_port=tk.StringVar(value=s["ptt_port"]), ptt_baud=tk.StringVar(value=str(s["ptt_baud"])),
            ptt_invert=tk.BooleanVar(value=s["ptt_invert"]),
            icom_model=tk.StringVar(value=s["ptt_icom_model"]), icom_addr=tk.StringVar(value=s["ptt_icom_addr"]),
            kenwood=tk.StringVar(value=s["ptt_kenwood"]),
            mon_rx=tk.BooleanVar(value=s["mon_rx"]), mon_tx=tk.BooleanVar(value=s["mon_tx"]),
            mon_level=tk.DoubleVar(value=s["mon_level"]),
            ptt_delay=tk.DoubleVar(value=s["ptt_delay"]), ptt_tail=tk.DoubleVar(value=s["ptt_tail"]),
            mute=tk.BooleanVar(value=s["mute_rx_on_tx"]),
            afc=tk.BooleanVar(value=s["afc"]), center=tk.DoubleVar(value=s["fixed_center"]),
            show_all=tk.BooleanVar(value=s["show_all"]),
            in_channel=tk.StringVar(value=IN_CHANNELS[int(s.get("in_channel") or 0)]),
            ring=tk.BooleanVar(value=s["ring"]),
            ring_style=tk.StringVar(value=dict(RING_STYLES).get(s["ring_style"], RING_STYLES[0][1])),
            answer_style=tk.StringVar(value=dict(RING_STYLES).get(s.get("answer_style", "kalinka"), RING_STYLES[-1][1])),
            ring_vol=tk.DoubleVar(value=s["ring_volume"]), ring_sec=tk.DoubleVar(value=s["ring_seconds"]),
            ring_air=tk.BooleanVar(value=s.get("ring_air", True)),
            ext_enabled=tk.BooleanVar(value=s.get("ext_enabled", False)),
            ext_port=tk.StringVar(value=s.get("ext_port", "")),
            ext_line=tk.StringVar(value=s.get("ext_line", "DTR")),
            ext_invert=tk.BooleanVar(value=s.get("ext_invert", False)),
            ext_sec=tk.DoubleVar(value=s.get("ext_seconds", 5.0)),
            listen=tk.BooleanVar(value=s.get("listen_after_call", True)),
            listen_sec=tk.DoubleVar(value=s.get("listen_seconds", 60.0)),
        )
        v = self.v

        f = ttk.LabelFrame(w, text="Передача", padding=6)
        f.grid(row=0, column=0, sticky="ew", padx=10, pady=(10, 4))
        ttk.Label(f, text="Преамбула (точки), с").grid(row=0, column=0, **pad)
        ttk.Spinbox(f, from_=0.4, to=12, increment=0.2, textvariable=v["dot"], width=6).grid(row=0, column=1, **pad)
        ttk.Label(f, text="Уровень").grid(row=1, column=0, **pad)
        ttk.Scale(f, from_=0.05, to=1.0, variable=v["level"], length=200).grid(row=1, column=1, **pad)
        ttk.Checkbutton(f, text="Транслитерировать кириллицу в сообщениях",
                        variable=v["translit"]).grid(row=2, column=0, columnspan=2, **pad)
        ttk.Label(f, text="Для станций в режиме сканирования — не меньше цикла сканирования (6–12 с).",
                  foreground="#666").grid(row=3, column=0, columnspan=2, **pad)

        f = ttk.LabelFrame(w, text="Управление передачей (PTT / CAT)", padding=6)
        f.grid(row=1, column=0, sticky="ew", padx=10, pady=4)
        ttk.Label(f, text="Метод").grid(row=0, column=0, **pad)
        cb = ttk.Combobox(f, textvariable=v["ptt_method"], values=[PTT_TITLES[m] for m in PTT.METHODS],
                          state="readonly", width=28)
        cb.grid(row=0, column=1, columnspan=3, **pad)
        cb.bind("<<ComboboxSelected>>", lambda ev: self.on_method())
        ttk.Label(f, text="COM-порт").grid(row=1, column=0, **pad)
        self.cb_port = ttk.Combobox(f, textvariable=v["ptt_port"], values=self.ports(), width=12)
        self.cb_port.grid(row=1, column=1, **pad)
        ttk.Label(f, text="Скорость").grid(row=1, column=2, **pad)
        ttk.Combobox(f, textvariable=v["ptt_baud"], values=[str(b) for b in PTT.BAUDS], width=8).grid(
            row=1, column=3, **pad)
        bf = ttk.Frame(f)
        bf.grid(row=2, column=1, columnspan=3, **pad)
        ttk.Button(bf, text="↻ порты", command=lambda: self.cb_port.configure(values=self.ports())).pack(side="left")
        ttk.Button(bf, text="Тест PTT (1 с)", command=self.test_ptt).pack(side="left", padx=4)
        ttk.Checkbutton(bf, text="Инверсия RTS/DTR", variable=v["ptt_invert"]).pack(side="left", padx=4)
        ttk.Label(f, text="ICOM: модель / адрес CI-V").grid(row=3, column=0, **pad)
        cm = ttk.Combobox(f, textvariable=v["icom_model"], values=list(PTT.ICOM_MODELS), state="readonly", width=16)
        cm.grid(row=3, column=1, columnspan=2, **pad)
        cm.bind("<<ComboboxSelected>>", lambda ev: self.on_icom())
        ttk.Entry(f, textvariable=v["icom_addr"], width=6).grid(row=3, column=3, **pad)
        ttk.Label(f, text="KENWOOD: команда TX").grid(row=4, column=0, **pad)
        ttk.Combobox(f, textvariable=v["kenwood"], values=PTT.KENWOOD_VARIANTS, state="readonly", width=6).grid(
            row=4, column=1, **pad)
        ttk.Label(f, text="Задержка PTT → сигнал, с").grid(row=5, column=0, **pad)
        ttk.Spinbox(f, from_=0, to=3, increment=0.1, textvariable=v["ptt_delay"], width=6).grid(row=5, column=1, **pad)
        ttk.Label(f, text="Хвост, с").grid(row=5, column=2, **pad)
        ttk.Spinbox(f, from_=0, to=2, increment=0.1, textvariable=v["ptt_tail"], width=6).grid(row=5, column=3, **pad)
        ttk.Checkbutton(f, text="Не принимать во время передачи (не слышать свой сигнал)",
                        variable=v["mute"]).grid(row=6, column=0, columnspan=4, **pad)
        ttk.Label(f, text="CAT-команды по документации производителей; проверяйте «Тестом PTT» на эквиваленте.",
                  foreground="#666").grid(row=7, column=0, columnspan=4, **pad)

        f = ttk.LabelFrame(w, text="Приём", padding=6)
        f.grid(row=2, column=0, sticky="ew", padx=10, pady=4)
        ttk.Checkbutton(f, text="Автоподстройка частоты (АПЧ)", variable=v["afc"]).grid(row=0, column=0, **pad)
        ttk.Label(f, text="Центр без АПЧ, Гц").grid(row=1, column=0, **pad)
        ttk.Spinbox(f, from_=1000, to=2600, increment=5, textvariable=v["center"], width=8).grid(row=1, column=1, **pad)
        ttk.Checkbutton(f, text="Показывать вызовы не на мой ID", variable=v["show_all"]).grid(
            row=2, column=0, columnspan=2, **pad)
        ttk.Label(f, text="Канал входа").grid(row=3, column=0, **pad)
        ttk.Combobox(f, textvariable=v["in_channel"], values=IN_CHANNELS, state="readonly", width=24).grid(
            row=3, column=1, **pad)

        f = ttk.LabelFrame(w, text="Самоконтроль (динамики, наушники — можно несколько)", padding=6)
        f.grid(row=0, column=1, rowspan=2, sticky="nsew", padx=10, pady=(10, 4))
        ttk.Checkbutton(f, text="Слушать эфир (вход)", variable=v["mon_rx"]).grid(row=0, column=0, **pad)
        ttk.Checkbutton(f, text="Слушать свою передачу", variable=v["mon_tx"]).grid(row=1, column=0, **pad)
        ttk.Label(f, text="Уровень самоконтроля").grid(row=2, column=0, **pad)
        ttk.Scale(f, from_=0.0, to=1.0, variable=v["mon_level"], length=180).grid(row=3, column=0, **pad)
        ttk.Label(f, text="Устройства:").grid(row=4, column=0, **pad)
        self.mon_vars = {}
        chosen = set(s.get("mon_devs") or [])
        names = [n for n in app.dev_out_names if n != "По умолчанию"]
        for i, n in enumerate(names):
            bv = tk.BooleanVar(value=n in chosen)
            self.mon_vars[n] = bv
            ttk.Checkbutton(f, text=n[:40], variable=bv).grid(row=5 + i, column=0, padx=16, pady=1, sticky="w")
        if not names:
            ttk.Label(f, text="(нет устройств вывода)", foreground="#666").grid(row=5, column=0, **pad)
        ttk.Label(f, text="Не отмечайте выход на трансивер —\nиначе самоконтроль уйдёт в эфир.",
                  foreground="#a60").grid(row=6 + len(names), column=0, **pad)

        f = ttk.LabelFrame(w, text="Звонок при вызове на мой ID", padding=6)
        f.grid(row=2, column=1, rowspan=2, sticky="nsew", padx=10, pady=4)
        ttk.Checkbutton(f, text="Звонить (на устройствах самоконтроля,\nесли не выбраны — системный выход)",
                        variable=v["ring"]).grid(row=0, column=0, columnspan=3, **pad)
        ttk.Label(f, text="Сигнал звонка").grid(row=1, column=0, **pad)
        ttk.Combobox(f, textvariable=v["ring_style"], values=[t for _, t in RING_STYLES], state="readonly",
                     width=26).grid(row=1, column=1, columnspan=2, **pad)
        ttk.Label(f, text="Громкость").grid(row=2, column=0, **pad)
        ttk.Scale(f, from_=0.05, to=1.0, variable=v["ring_vol"], length=120).grid(row=2, column=1, **pad)
        ttk.Button(f, text="Прослушать", command=self.test_ring).grid(row=2, column=2, **pad)
        ttk.Label(f, text="Не дольше, с").grid(row=3, column=0, **pad)
        ttk.Spinbox(f, from_=5, to=300, increment=5, textvariable=v["ring_sec"], width=6).grid(row=3, column=1, **pad)
        ttk.Checkbutton(f, text="Ответ в эфир — вызывающая станция слышит, что вызов\nпринят (один раз, уровень передачи)",
                        variable=v["ring_air"]).grid(row=4, column=0, columnspan=3, **pad)
        ttk.Label(f, text="Сигнал ответа").grid(row=5, column=0, **pad)
        ttk.Combobox(f, textvariable=v["answer_style"], values=[t for _, t in RING_STYLES], state="readonly",
                     width=26).grid(row=5, column=1, **pad)
        ttk.Button(f, text="Прослушать", command=self.test_answer).grid(row=5, column=2, **pad)

        f = ttk.LabelFrame(w, text="Внешнее устройство (отдельный COM-порт, не порт PTT)", padding=6)
        f.grid(row=4, column=0, columnspan=2, sticky="ew", padx=10, pady=4)
        ttk.Checkbutton(f, text="Включать при вызове на мой ID", variable=v["ext_enabled"]).grid(
            row=0, column=0, columnspan=2, **pad)
        ttk.Label(f, text="COM-порт").grid(row=1, column=0, **pad)
        self.cb_ext = ttk.Combobox(f, textvariable=v["ext_port"], values=self.ext_ports(), width=12)
        self.cb_ext.grid(row=1, column=1, **pad)
        ttk.Label(f, text="Линия").grid(row=1, column=2, **pad)
        ttk.Combobox(f, textvariable=v["ext_line"], values=EXT_LINES, state="readonly", width=9).grid(
            row=1, column=3, **pad)
        ttk.Checkbutton(f, text="Инверсия", variable=v["ext_invert"]).grid(row=1, column=4, **pad)
        ttk.Label(f, text="Время сигнала, с (1–60)").grid(row=2, column=0, **pad)
        ttk.Spinbox(f, from_=1, to=60, increment=1, textvariable=v["ext_sec"], width=6).grid(row=2, column=1, **pad)
        ttk.Button(f, text="Проверить (импульс)", command=self.test_ext).grid(row=2, column=2, columnspan=2, **pad)
        ttk.Label(f, text="Кнопка «Внешн.» на панели включает выход вручную, пока не нажмёте её снова.",
                  foreground="#666").grid(row=3, column=0, columnspan=5, **pad)

        f = ttk.LabelFrame(w, text="Прослушивание эфира после вызова (чтобы услышать голосовое сообщение)",
                           padding=6)
        f.grid(row=5, column=0, columnspan=2, sticky="ew", padx=10, pady=4)
        ttk.Checkbutton(f, text="Включать после вызова на мой ID: вызов → ответ в эфир → вход звучит на устройствах "
                                "самоконтроля (или системном выходе)", variable=v["listen"]).grid(
            row=0, column=0, columnspan=3, **pad)
        ttk.Label(f, text="Время прослушивания, с (5–600)").grid(row=1, column=0, **pad)
        ttk.Spinbox(f, from_=5, to=600, increment=5, textvariable=v["listen_sec"], width=6).grid(
            row=1, column=1, **pad)
        ttk.Label(f, text="Кнопка «Слушать» на панели — вручную.", foreground="#666").grid(row=1, column=2, **pad)

        b = ttk.Frame(w, padding=(10, 8))
        b.grid(row=6, column=0, columnspan=2, sticky="ew")
        ttk.Button(b, text="Очистить журнал", command=self.clear_log).pack(side="left")
        ttk.Button(b, text="Готово", command=self.close).pack(side="right")
        w.protocol("WM_DELETE_WINDOW", self.close)
        w.grab_set()

    @staticmethod
    def ports():
        return [d for d, _ in PTT.list_ports()]

    def ext_ports(self):
        """порты для внешнего устройства — все, кроме порта PTT/CAT"""
        s = self.app.core.s
        busy = s["ptt_port"] if s["ptt_method"] != "none" else None
        return [p for p in self.ports() if p != busy]

    def test_ext(self):
        self.apply()
        self.app.core.ext_pulse()

    def on_method(self):
        m = next((k for k, t in PTT_TITLES.items() if t == self.v["ptt_method"].get()), "none")
        self.v["ptt_baud"].set(str(PTT.DEFAULT_BAUD.get(m, 9600)))

    def on_icom(self):
        a = PTT.ICOM_MODELS.get(self.v["icom_model"].get())
        if a:
            self.v["icom_addr"].set("%02X" % a)

    def _num(self, var, lo, hi, default):
        try:
            return max(lo, min(hi, float(str(var.get()).replace(",", "."))))
        except Exception:
            return default

    def apply(self):
        s = self.app.core.s
        v = self.v
        s["dot_seconds"] = self._num(v["dot"], 0.4, 12, 6.0)
        s["tx_level"] = self._num(v["level"], 0.05, 1.0, 0.5)
        s["translit"] = bool(v["translit"].get())
        s["ptt_method"] = next((k for k, t in PTT_TITLES.items() if t == v["ptt_method"].get()), "none")
        s["ptt_port"] = v["ptt_port"].get().strip()
        s["ptt_baud"] = int(self._num(v["ptt_baud"], 300, 115200, 9600))
        s["ptt_invert"] = bool(v["ptt_invert"].get())
        s["ptt_icom_model"] = v["icom_model"].get()
        s["ptt_icom_addr"] = v["icom_addr"].get().strip() or "94"
        s["ptt_kenwood"] = v["kenwood"].get() or "TX;"
        s["mon_rx"] = bool(v["mon_rx"].get())
        s["mon_tx"] = bool(v["mon_tx"].get())
        s["mon_level"] = self._num(v["mon_level"], 0.0, 1.0, 0.5)
        s["mon_devs"] = [n for n, bv in self.mon_vars.items() if bv.get()]
        s["ptt_delay"] = self._num(v["ptt_delay"], 0, 3, 0.5)
        s["ptt_tail"] = self._num(v["ptt_tail"], 0, 2, 0.3)
        s["mute_rx_on_tx"] = bool(v["mute"].get())
        s["afc"] = bool(v["afc"].get())
        s["fixed_center"] = self._num(v["center"], 1000, 2600, S.F_CENTER)
        s["show_all"] = bool(v["show_all"].get())
        s["in_channel"] = IN_CHANNELS.index(v["in_channel"].get()) if v["in_channel"].get() in IN_CHANNELS else 0
        s["ring"] = bool(v["ring"].get())
        s["ring_style"] = next((k for k, t in RING_STYLES if t == v["ring_style"].get()), "codan")
        s["answer_style"] = next((k for k, t in RING_STYLES if t == v["answer_style"].get()), "kalinka")
        s["ring_volume"] = self._num(v["ring_vol"], 0.05, 1.0, 0.5)
        s["ring_seconds"] = self._num(v["ring_sec"], 5, 300, 30)
        s["ring_air"] = bool(v["ring_air"].get())
        old = (s.get("ext_port"), s.get("ext_line"), s.get("ext_invert"))
        s["ext_enabled"] = bool(v["ext_enabled"].get())
        s["ext_port"] = v["ext_port"].get().strip()
        s["ext_line"] = v["ext_line"].get() if v["ext_line"].get() in EXT_LINES else "DTR"
        s["ext_invert"] = bool(v["ext_invert"].get())
        s["ext_seconds"] = self._num(v["ext_sec"], 1, 60, 5)
        s["listen_after_call"] = bool(v["listen"].get())
        s["listen_seconds"] = self._num(v["listen_sec"], 5, 600, 60)
        if old != (s["ext_port"], s["ext_line"], s["ext_invert"]):
            self.app.core.ext.close(old[1] or "RTS+DTR", bool(old[2]))
            self.app.core.ext_manual = False
        self.app.core.save()
        err = self.app.core.reopen_ptt()
        if err:
            self.app.add("PTT: %s" % err, "error")
        for e in self.app.core.apply_monitor():
            self.app.add("Самоконтроль: %s" % e, "error")
        if self.app.core.ext_conflict():
            self.app.add("Внешнее устройство: порт %s занят PTT/CAT — нужен отдельный COM-порт" % s["ext_port"],
                         "error")
        if s["out_dev"] and s["out_dev"] in s["mon_devs"]:
            self.app.add("Выход на трансивер отмечен в самоконтроле: звук самоконтроля и звонок уйдут в эфир!",
                         "error")

    def test_ptt(self):
        self.apply()
        self.app.core.test_ptt()

    def test_ring(self):
        self.apply()
        self.app.core.ring(seconds=4)

    def test_answer(self):
        self.apply()
        self.app.core.ring(seconds=4, answer=True)

    def clear_log(self):
        t = self.app.text
        t.configure(state="normal")
        t.delete("1.0", "end")
        t.configure(state="disabled")

    def close(self):
        self.apply()
        self.w.grab_release()
        self.w.destroy()


# ============================================================================ самопроверка
def selftest(out_path):
    lines = []

    def log(s):
        lines.append(s)
        print(s)

    ok = True
    log("%s %s, Python %s, %s" % (APP_NAME, VERSION, sys.version.split()[0], sys.platform))
    log("numpy %s, sounddevice %s, pyserial %s" % (
        np.__version__, getattr(sd, "__version__", "НЕТ (%s)" % SD_ERROR),
        getattr(serial, "VERSION", "НЕТ (%s)" % SERIAL_ERROR)))
    ok = ok and sd is not None and serial is not None
    # кодер -> 48 кГц -> Downsampler (как в живом приёме) -> потоковый декодер
    fs = 48000
    y = S.modulate(S.build_call("1234", "5678", "TEST 73"), fs, 1.0)
    y = np.concatenate((np.zeros(fs), y, np.zeros(2 * fs)))
    y = y + np.random.default_rng(3).normal(0, 0.2, len(y))
    d = Downsampler(fs)
    rx = S.StreamReceiver(RX_FS)
    got = []
    for i in range(0, len(y), 4800):
        rx.append(d.push(y[i:i + 4800]))
        if (i // 4800) % 10 == 9:
            got += rx.process()
    got += rx.process(flush=True)
    good = len(got) == 1 and got[0]["message"] == "TEST 73" and got[0]["ecc_ok"]
    log("live chain 48k -> 8k -> stream decoder: %s" % ("OK" if good else "FAIL %r" % got))
    ok = ok and good
    for fs_in in (44100, 8000):
        z = S.modulate(S.build_call("1234", "1111"), fs_in, 1.0)
        dd = Downsampler(fs_in)
        zz = np.concatenate([dd.push(z[i:i + 1000]) for i in range(0, len(z), 1000)])
        r = S.decode(zz, RX_FS)
        good = len(r) == 1 and r[0]["from"] == "1111"
        log("downsampler %d -> 8000: %s" % (fs_in, "OK" if good else "FAIL"))
        ok = ok and good
    c = Core.__new__(Core)
    c.s = dict(DEFAULTS)
    c.level, c.active_channel, c.ch_energy, c.mute_until = 0.0, 1, None, 0.0
    c.down = Downsampler(48000)
    c.audio_q = queue.Queue()
    c.monitor = Monitor()
    stereo = np.zeros((4800, 2), np.float32)
    stereo[:, 1] = 0.9 * np.sin(np.arange(4800) * 0.2)          # сигнал только во втором канале
    for _ in range(5):
        c._on_audio(stereo, 4800, None, None)
    good = c.active_channel == 2 and c.level > 0.85
    log("input channel auto-select + peak level: %s (channel %d, level %.2f)" % (
        "OK" if good else "FAIL", c.active_channel, c.level))
    ok = ok and good
    c2 = Core.__new__(Core)
    c2.s = dict(DEFAULTS)
    c2.tx_queue, c2.transmitting = [], True          # не запускать воспроизведение в самотесте
    if sd is not None:
        c2.send_ring("1111")
        a = c2.tx_queue[0][0] if c2.tx_queue else np.zeros(0)
        fs_ = c2.tx_queue[0][1] if c2.tx_queue else 48000
        want = 16 * KALINKA_QUARTER + DEFAULTS["ptt_delay"] + DEFAULTS["ptt_tail"]
        good = abs(len(a) / fs_ - want) < 0.02 and np.abs(a).max() <= DEFAULTS["tx_level"] + 0.01
        log("answer on air (kalinka once + PTT delay/tail): %s (%.2f s)" % ("OK" if good else "FAIL", len(a) / fs_))
        ok = ok and good
    c3 = Core.__new__(Core)
    c3.s = dict(DEFAULTS, ptt_method="RTS", ptt_port="COM3", ext_port="COM3")
    c3.q = queue.Queue()
    c3.ext, c3.ext_manual, c3.ext_timer = ExtControl(), False, None
    c3.ext_pulse(2)
    good = c3.ext_conflict() and not c3.ext.on and not c3.q.empty()
    c3.s["ext_port"] = "COM4"
    good = good and not c3.ext_conflict()
    log("external device: separate port enforced: %s" % ("OK" if good else "FAIL"))
    ok = ok and good
    c4 = Core.__new__(Core)
    c4.s = dict(DEFAULTS, mon_devs=[], mon_rx=False, mon_tx=False)
    c4.q = queue.Queue()
    c4.monitor = Monitor()
    c4.ring_timer, c4.ring_players = None, []
    c4.receiving, c4.listening, c4.listen_manual, c4.listen_timer, c4.listen_pending = True, False, False, None, False
    c4.start_listen(5)
    good = c4.listening and c4.listen_timer is not None
    c4.listen_timer.cancel()
    c4.toggle_listen()
    good = good and not c4.listening
    log("listen after call (timer + manual toggle): %s" % ("OK" if good else "FAIL"))
    ok = ok and good
    k = ring_pattern("kalinka", 8000, 0.5)
    melody = (len(k) / 8000.0) - 0.8
    good = abs(melody - 16 * KALINKA_QUARTER) < 0.05 and np.abs(k).max() <= 0.5
    log("kalinka melody: %s (%.2f s + pause)" % ("OK" if good else "FAIL", melody))
    ok = ok and good
    pat = ring_pattern("codan", 48000, 0.5)
    log("ring pattern: %s" % ("OK" if len(pat) > 0 and np.abs(pat).max() <= 0.51 else "FAIL"))
    cat = [PTT.command_bytes("ICOM", True, 0x94), PTT.command_bytes("YAESU", True),
           PTT.command_bytes("YAESU-OLD", False), PTT.command_bytes("KENWOOD", False)]
    good = cat == [bytes([0xFE, 0xFE, 0x94, 0xE0, 0x1C, 0x00, 0x01, 0xFD]), b"TX1;", bytes([0, 0, 0, 0, 0x88]), b"RX;"]
    log("CAT commands: %s" % ("OK" if good else "FAIL %r" % cat))
    ok = ok and good
    m = Monitor()
    o = dict(fs=48000, buf=np.zeros(0, np.float32), lock=threading.Lock())
    m.outs["test"] = o
    m.feed(np.ones(4000, np.float32))
    out = np.zeros((1000, 1), np.float32)
    m.level = 0.25
    m._cb(o)(out, 1000, None, None)
    good = len(o["buf"]) == int(0.5 * 48000) - 1000 and abs(out[500, 0] - 0.25) < 1e-6
    log("monitor buffer/level: %s" % ("OK" if good else "FAIL"))
    ok = ok and good
    log("serial ports: %s" % ([d for d, _ in PTT.list_ports()] or "нет"))
    if sd is not None:
        try:
            log("audio devices (MME): %d" % len(list_devices()))
        except Exception as ex:
            log("audio devices: ошибка %s" % ex)
    log("SELFTEST %s" % ("OK" if ok else "FAIL"))
    try:
        with open(out_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    except Exception:
        pass
    return ok


def main():
    if "--selftest" in sys.argv:
        base = os.path.dirname(sys.executable if getattr(sys, "frozen", False) else os.path.abspath(__file__))
        sys.exit(0 if selftest(os.path.join(base, "selftest.txt")) else 1)
    root = tk.Tk()
    try:
        ttk.Style().theme_use("vista" if sys.platform.startswith("win") else "clam")
    except Exception:
        pass
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
