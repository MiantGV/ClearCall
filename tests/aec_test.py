#!/usr/bin/env python3
"""Simulated speakerphone call to check ClearCall's echo cancellation and automatic gain.

Two synthetic voices (macOS `say`): the far end (the other person, played on the speakers)
and the near end (you, recorded quietly by the laptop mic). The mic picks up a delayed,
reverberant, slightly distorted copy of the far end (echo) plus your quiet voice and noise.

Usage: aec_test.py <aec_test binary> <work dir>
"""
import os
import subprocess
import sys

import numpy as np

SR = 48000
BIN, WORK = sys.argv[1], sys.argv[2]
os.makedirs(WORK, exist_ok=True)


def say(text, voice, name):
    aiff = os.path.join(WORK, name + ".aiff")
    wav = os.path.join(WORK, name + ".wav")
    subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32@48000", "-c", "1", aiff, wav], check=True)
    data = open(wav, "rb").read()
    i = data.find(b"data")
    x = np.frombuffer(data[i + 8:], dtype="<f4").astype(np.float64)
    return x / (np.max(np.abs(x)) + 1e-9)


def rms_db(x):
    return 20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-12)


far_text = ("Hi, can you hear me alright? I wanted to talk about the plans for next weekend. "
            "We could drive up to the mountains on Saturday morning and come back on Sunday. "
            "What do you think about that idea?")
near_text = ("Yes, I can hear you well. That sounds like a great plan to me. "
             "Saturday morning works, and I can bring the food for the trip.")
far = say(far_text, "Samantha", "far")
near = say(near_text, "Daniel", "near")

# Timeline: far talks alone, then near talks alone, then both talk together (double talk).
gap = int(0.5 * SR)
T = len(far) + gap + len(near) + gap + len(near[: 4 * SR]) + SR
ref = np.zeros(T)
nearsig = np.zeros(T)
ref[: len(far)] = 0.5 * far                                  # call audio at a normal level
n0 = len(far) + gap
nearsig[n0: n0 + len(near)] = near
d0 = n0 + len(near) + gap                                     # double-talk section
nearsig[d0: d0 + 4 * SR] += near[: 4 * SR]
ref[d0: d0 + 4 * SR] += 0.5 * far[: 4 * SR]

# Echo path: 30 ms delay (output + air), simple room reverb, mild speaker distortion.
rng = np.random.default_rng(1)
delay = int(0.030 * SR)
ir_len = int(0.15 * SR)
ir = rng.standard_normal(ir_len) * np.exp(-np.arange(ir_len) / (0.03 * SR))
ir[0] = 3.0
ir /= np.sqrt(np.sum(ir ** 2))
played = np.tanh(1.5 * ref) / 1.5
echo = np.convolve(played, ir)[:T]
echo = np.concatenate([np.zeros(delay), echo])[:T] * 0.25     # echo at the mic
near_quiet = nearsig * 0.02                                   # your voice is quiet (about -40 dB)
noise = rng.standard_normal(T) * 10 ** (-65 / 20)
mic = echo + near_quiet + noise

for name, arr in (("ref", ref), ("mic", mic)):
    arr.astype("<f4").tofile(os.path.join(WORK, name + ".f32"))

far_only = slice(0, len(far))
near_only = slice(n0, n0 + len(near))
second_half_far = slice(len(far) // 2, len(far))              # after the canceller has adapted

print(f"Input:  call audio {rms_db(ref[far_only]):6.1f} dB | echo in mic {rms_db(mic[second_half_far]):6.1f} dB"
      f" | your voice in mic {rms_db(mic[near_only]):6.1f} dB")

results = {}
for label, aec, agc in (("echo removal + auto gain", 1, 1), ("auto gain only", 0, 1)):
    out_path = os.path.join(WORK, f"out_{aec}{agc}.f32")
    subprocess.run([BIN, os.path.join(WORK, "ref.f32"), os.path.join(WORK, "mic.f32"), out_path, str(aec), str(agc)], check=True)
    out = np.fromfile(out_path, dtype="<f4").astype(np.float64)
    echo_left = rms_db(out[second_half_far])
    voice = rms_db(out[near_only][len(near) // 2:])           # level once the gain has settled
    results[label] = (echo_left, voice)
    print(f"{label:26s}: echo left {echo_left:6.1f} dB | your voice {voice:6.1f} dB")

echo_left, voice = results["echo removal + auto gain"]
_, voice_no_aec = results["auto gain only"]
echo_reduction = rms_db(mic[second_half_far]) - echo_left
print(f"\nEcho reduced by {echo_reduction:.1f} dB; your voice raised from {rms_db(mic[near_only]):.1f} to {voice:.1f} dB "
      f"(call audio is {rms_db(ref[far_only]):.1f} dB)")

ok = echo_reduction >= 20 and voice >= rms_db(ref[far_only]) - 10
print("RESULT:", "PASS" if ok else "CHECK")
