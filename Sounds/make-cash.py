# Synthesizes PulseMRR's cash register sound from scratch (no samples, so no rights issue):
# a short drawer "ka", then a two-strike metallic bell "ching" and a few coin ticks.
import math, random, struct, wave, sys

RATE = 44100
DUR = 1.25
n = int(RATE * DUR)
out = [0.0] * n
random.seed(7)

def add(start, samples):
    i0 = int(start * RATE)
    for i, v in enumerate(samples):
        if 0 <= i0 + i < n:
            out[i0 + i] += v

# "ka": a dull thump plus a filtered noise click, about 60 ms
ka, lp = [], 0.0
for i in range(int(0.06 * RATE)):
    t = i / RATE
    env = math.exp(-t * 70)
    lp += 0.25 * (random.uniform(-1, 1) - lp)
    ka.append(env * (0.55 * lp + 0.45 * math.sin(2 * math.pi * 140 * t)))
add(0.0, ka)

# "ching": inharmonic bell partials, each with its own decay
def bell(f0, amp, length):
    partials = [(1.0, 1.0, 6.0), (2.76, 0.55, 9.0), (5.40, 0.35, 13.0), (8.93, 0.18, 18.0)]
    s = []
    for i in range(int(length * RATE)):
        t = i / RATE
        attack = min(1.0, t / 0.002)
        v = sum(a * math.exp(-t * d) * math.sin(2 * math.pi * f0 * r * t) for r, a, d in partials)
        s.append(amp * attack * v)
    return s
add(0.07, bell(2093.0, 0.42, 1.15))
add(0.16, bell(2637.0, 0.30, 1.05))

# coins: tiny high ticks scattered just after the bell
for k in range(6):
    start = 0.10 + random.uniform(0, 0.35)
    f = random.uniform(4200, 6800)
    tick = [0.12 * math.exp(-(i / RATE) * 160) * math.sin(2 * math.pi * f * i / RATE) for i in range(int(0.04 * RATE))]
    add(start, tick)

# fade out and normalise
for i in range(n):
    tail = max(0.0, (i / RATE - (DUR - 0.25)) / 0.25)
    out[i] *= (1 - tail)
peak = max(abs(v) for v in out) or 1
with wave.open(sys.argv[1], "w") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
    w.writeframes(b"".join(struct.pack("<h", int(v / peak * 0.85 * 32767)) for v in out))
