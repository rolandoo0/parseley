"""Builds the tour video's soundtrack and muxes it into the MP4.

Narration: Kokoro text-to-speech (open source, runs offline), one line per scene from
narration.json. Under it: a quiet synthesized music bed and soft key clicks at the
moments keys appear on screen.

    pip install kokoro-onnx soundfile numpy
    # model files: github.com/thewh1teagle/kokoro-onnx/releases (model-files-v1.0)
    python scripts/tour-video/make_audio.py --model kokoro-v1.0.int8.onnx --voices voices-v1.0.bin \
        --video App/Resources/ParseleyTour.mp4
"""
import argparse, json, os, subprocess, tempfile

import numpy as np
import soundfile as sf
from kokoro_onnx import Kokoro

SR = 24000
HERE = os.path.dirname(os.path.abspath(__file__))


def speak(kokoro, text, voice, max_seconds):
    """Synthesizes `text`, speeding up (to 1.2x at most) until it fits in max_seconds."""
    speed = 1.0
    while True:
        samples, sr = kokoro.create(text, voice=voice, speed=speed, lang="en-us")
        assert sr == SR
        if len(samples) / SR <= max_seconds or speed >= 1.2:
            return samples, speed
        speed = min(1.2, speed * (len(samples) / SR) / max_seconds + 0.01)


def music_bed(seconds):
    """A soft, slowly changing chord pad (sine partials, gentle tremolo), very quiet."""
    t = np.arange(int(seconds * SR)) / SR
    chords = [  # Hz: Cmaj9, Am7, Fmaj7, G6, looping every 8 s each
        [130.81, 196.00, 246.94, 293.66], [110.00, 164.81, 196.00, 261.63],
        [87.31, 130.81, 164.81, 220.00], [98.00, 146.83, 196.00, 246.94],
    ]
    out = np.zeros_like(t)
    seg = 8.0
    for i in range(int(np.ceil(seconds / seg)) + 1):
        notes = chords[i % len(chords)]
        start = i * seg
        env = np.clip((t - start + 1.5) / 1.5, 0, 1) * np.clip((start + seg + 1.5 - t) / 1.5, 0, 1)
        for k, f in enumerate(notes):
            out += env * np.sin(2 * np.pi * f * t + k) * (0.5 if k == 0 else 0.3)
            out += env * 0.08 * np.sin(2 * np.pi * 2 * f * t)
    out *= 1 + 0.15 * np.sin(2 * np.pi * 0.25 * t)       # slow movement
    fade = np.clip(t / 2.0, 0, 1) * np.clip((seconds - t) / 3.0, 0, 1)
    out *= fade
    return out / np.max(np.abs(out)) * 0.06                # about -24 dBFS


def click():
    """A short, soft keyboard tick."""
    n = int(0.03 * SR)
    noise = np.random.default_rng(7).standard_normal(n)
    env = np.exp(-np.arange(n) / (0.004 * SR))
    tone = np.sin(2 * np.pi * 1800 * np.arange(n) / SR)
    return (0.6 * noise + 0.4 * tone) * env * 0.12


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--voices", required=True)
    ap.add_argument("--video", required=True)
    ap.add_argument("--duration", type=float, default=86.0)
    args = ap.parse_args()

    spec = json.load(open(os.path.join(HERE, "narration.json")))
    kokoro = Kokoro(args.model, args.voices)
    total = int(args.duration * SR)
    voice_track = np.zeros(total)
    voice_mask = np.zeros(total)
    for line in spec["lines"]:
        begin = line["start"] + (0.0 if line["start"] < 0.5 else 0.35)
        samples, speed = speak(kokoro, line["text"], spec["voice"], line["end"] - begin - 0.25)
        a = int(begin * SR)
        b = min(total, a + len(samples))
        voice_track[a:b] += samples[: b - a]
        voice_mask[a:b] = 1
        print(f"{line['start']:5.1f}s  {len(samples)/SR:4.1f}s  x{speed:.2f}  {line['text']}")

    # Duck the music while someone is speaking (smoothed so it doesn't pump).
    kernel = np.ones(int(0.4 * SR)) / int(0.4 * SR)
    duck = 1 - 0.55 * np.convolve(voice_mask, kernel, mode="same")
    mix = voice_track * 0.95 + music_bed(args.duration) * duck
    tick = click()
    for c in spec["clicks"]:
        a = int(c * SR)
        mix[a : a + len(tick)] += tick
    mix = np.clip(mix, -0.98, 0.98)

    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "mix.wav")
        sf.write(wav, mix.astype(np.float32), SR)
        out = os.path.join(tmp, "out.mp4")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", args.video, "-i", wav,
                        "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy",
                        # Normalize to -16 LUFS (typical for app/web video), peaks under -1.5 dB.
                        "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "48000", "-c:a", "aac", "-b:a", "128k",
                        "-shortest", "-movflags", "+faststart", out], check=True)
        os.replace(out, args.video)
    print("wrote", args.video)


if __name__ == "__main__":
    main()
