#!/usr/bin/env python3
"""Writes the app's simulated sync + IF (SyncIFSimulator) to a 48 kHz float32 stereo .wav, for
comparing the web and Mac apps on identical samples:  make_sim_wav.py out.wav [seconds] [Tp ms]"""
import math, random, struct, sys

out = sys.argv[1]
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 6
tp = (float(sys.argv[3]) if len(sys.argv) > 3 else 5) * 1e-3
fs, c = 48000, 3e8
f0, f1 = 2257.4e6, 2591.8e6
bw = f1 - f0
period = 2 * tp * fs * 1.000371
a_hp = math.exp(-2 * math.pi * 5 / fs)
random.seed(1)
hp = hp_prev = 0.0
frames = bytearray()
for s in range(int(secs * fs)):
    sq = math.tanh(100 * math.sin(2 * math.pi * s / period))
    hp = a_hp * (hp + sq - hp_prev); hp_prev = sq
    left = -0.45 * hp
    ph = math.fmod(s, period) / period
    up = ph < 0.5
    tr = (ph if up else ph - 0.5) * period / fs
    fb = lambda r: 2 * r * bw / (c * tp) * (1 if up else 0.92)
    r2 = 25 + 12 * math.sin(2 * math.pi * 0.015 * s / fs)
    carrier = 4 * math.pi * f0 * r2 / c
    v = (0.08 * math.sin(2 * math.pi * fb(8) * tr + 0.3) + 0.03 * math.sin(2 * math.pi * fb(r2) * tr + 1.1 + carrier)
         + 0.01 * math.sin(2 * math.pi * fb(60) * tr) + 0.15 * (tr / tp if up else 1 - tr / tp)
         + 0.002 * (random.random() - 0.5))
    frames += struct.pack('<ff', left, -v)
hdr = b'RIFF' + struct.pack('<I', 36 + len(frames)) + b'WAVE'
hdr += b'fmt ' + struct.pack('<IHHIIHH', 16, 3, 2, fs, fs * 8, 8, 32)
hdr += b'data' + struct.pack('<I', len(frames))
open(out, 'wb').write(hdr + frames)
print(f'{out}: {secs} s, Tp {tp*1e3:g} ms')
