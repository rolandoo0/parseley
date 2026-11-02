"""Soundtrack for the tour video: narration, a quiet music bed and key clicks.

Narration clips live in voice/NN.mp3, one per line of narration.json (generated with
Higgsfield's Seed Audio model, preset voice "Ainsley"). The voice is slower than the
original timeline, so scenes stretch to fit it:

    python make_audio.py plan        # measure clips → timing.json (scene lengths)
    node render.js                   # renders the video using timing.json
    python make_audio.py mix --video ../../App/Resources/ParseleyTour.mp4

Needs numpy and ffmpeg.
"""
import argparse, json, os, subprocess, tempfile

import numpy as np

SR = 24000
HERE = os.path.dirname(os.path.abspath(__file__))
LEAD = 0.35        # silence before a line starts, after its scene begins
TAIL = 0.45        # breathing room after a line, before the next scene
MAX_TEMPO = 1.10   # speed a line up by at most 10%; beyond that the scene gets longer


def load(path):
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-f", "f32le", "-ac", "1",
                          "-ar", str(SR), "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).copy()


def tighten(x, thresh_db=-40, max_pause=0.28):
    """Trims leading/trailing silence and shortens long pauses inside the line."""
    win = int(0.02 * SR)
    n = len(x) // win
    rms = np.sqrt(np.mean(x[: n * win].reshape(n, win) ** 2, axis=1) + 1e-12)
    loud = 20 * np.log10(rms) > thresh_db
    idx = np.where(loud)[0]
    if len(idx) == 0:
        return x
    keep, gap = [], 0
    for k in range(idx[0], idx[-1] + 1):
        gap = 0 if loud[k] else gap + 1
        if gap * 0.02 <= max_pause:
            keep.append(k)
    y = np.concatenate([x[k * win : (k + 1) * win] for k in keep])
    fade = int(0.01 * SR)   # avoid clicks at the cut points
    y[:fade] *= np.linspace(0, 1, fade)
    y[-fade:] *= np.linspace(1, 0, fade)
    return y


def tempo(x, factor):
    """Speeds up speech without changing pitch (ffmpeg atempo)."""
    if abs(factor - 1) < 0.005:
        return x
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "in.f32")
        x.astype(np.float32).tofile(src)
        raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "f32le", "-ar", str(SR), "-ac", "1",
                              "-i", src, "-af", f"atempo={factor:.4f}", "-f", "f32le", "-"],
                             capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).copy()


def plan(spec):
    """Scene lengths in the final video: the original length, or longer to fit the voice."""
    lines, segments, t_video = spec["lines"], [], 0.0
    for i, line in enumerate(lines):
        start = 0.0 if i == 0 else line["start"]
        end = line["end"]
        speech = len(tighten(load(os.path.join(HERE, "voice", f"{i:02d}.mp3")))) / SR
        lead = line["start"] if i == 0 else LEAD
        original = end - start
        needed = lead + speech / MAX_TEMPO + TAIL
        length = max(original, needed)
        speed = max(1.0, speech / (length - lead - TAIL))
        segments.append({"content_start": start, "content_end": end, "video_start": round(t_video, 3),
                         "video_end": round(t_video + length, 3), "tempo": round(speed, 4), "lead": lead})
        print(f"{i:02d} scene {original:4.1f}s → {length:4.1f}s  voice {speech:4.1f}s  x{speed:.2f}")
        t_video += length
    return {"segments": segments, "duration": round(t_video, 3)}


def video_time(timing, t):
    """Original timeline time → stretched video time."""
    for s in timing["segments"]:
        if s["content_start"] <= t < s["content_end"]:
            p = (t - s["content_start"]) / (s["content_end"] - s["content_start"])
            return s["video_start"] + p * (s["video_end"] - s["video_start"])
    return timing["duration"]


def music_bed(seconds):
    """A soft, slowly changing chord pad (sine partials), very quiet."""
    t = np.arange(int(seconds * SR)) / SR
    chords = [[130.81, 196.00, 246.94, 293.66], [110.00, 164.81, 196.00, 261.63],
              [87.31, 130.81, 164.81, 220.00], [98.00, 146.83, 196.00, 246.94]]
    out, seg = np.zeros_like(t), 8.0
    for i in range(int(np.ceil(seconds / seg)) + 1):
        start = i * seg
        env = np.clip((t - start + 1.5) / 1.5, 0, 1) * np.clip((start + seg + 1.5 - t) / 1.5, 0, 1)
        for k, f in enumerate(chords[i % len(chords)]):
            out += env * np.sin(2 * np.pi * f * t + k) * (0.5 if k == 0 else 0.3)
            out += env * 0.08 * np.sin(2 * np.pi * 2 * f * t)
    out *= 1 + 0.15 * np.sin(2 * np.pi * 0.25 * t)
    out *= np.clip(t / 2.0, 0, 1) * np.clip((seconds - t) / 3.0, 0, 1)
    return out / np.max(np.abs(out)) * 0.06


def click():
    n = int(0.03 * SR)
    noise = np.random.default_rng(7).standard_normal(n)
    env = np.exp(-np.arange(n) / (0.004 * SR))
    return (0.6 * noise + 0.4 * np.sin(2 * np.pi * 1800 * np.arange(n) / SR)) * env * 0.12


def mix(spec, timing, video):
    total = int(timing["duration"] * SR)
    voice, mask = np.zeros(total), np.zeros(total)
    for i, seg in enumerate(timing["segments"]):
        y = tempo(tighten(load(os.path.join(HERE, "voice", f"{i:02d}.mp3"))), seg["tempo"])
        a = int((seg["video_start"] + seg["lead"]) * SR)
        b = min(total, a + len(y))
        voice[a:b] += y[: b - a]
        mask[a:b] = 1
    voice *= 0.5 / max(1e-6, np.max(np.abs(voice)))
    kernel = np.ones(int(0.4 * SR)) / int(0.4 * SR)
    duck = 1 - 0.55 * np.convolve(mask, kernel, mode="same")
    out = voice + music_bed(timing["duration"]) * duck
    tick = click()
    for c in spec["clicks"]:
        a = int(video_time(timing, c) * SR)
        out[a : a + len(tick)] += tick
    out = np.clip(out, -0.98, 0.98).astype(np.float32)

    with tempfile.TemporaryDirectory() as tmp:
        pcm = os.path.join(tmp, "mix.f32")
        out.tofile(pcm)
        dst = os.path.join(tmp, "out.mp4")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", video,
                        "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", pcm,
                        "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy",
                        # Normalize to -16 LUFS (typical for app/web video), peaks under -1.5 dB.
                        "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "48000", "-c:a", "aac", "-b:a", "128k",
                        "-shortest", "-movflags", "+faststart", dst], check=True)
        os.replace(dst, video)
    print("wrote", video)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("step", choices=["plan", "mix"])
    ap.add_argument("--video", default=os.path.join(HERE, "..", "..", "App", "Resources", "ParseleyTour.mp4"))
    args = ap.parse_args()
    spec = json.load(open(os.path.join(HERE, "narration.json")))
    timing_path = os.path.join(HERE, "timing.json")
    if args.step == "plan":
        timing = plan(spec)
        json.dump(timing, open(timing_path, "w"), indent=1)
        print(f"video length {timing['duration']:.1f}s → {timing_path}")
    else:
        mix(spec, json.load(open(timing_path)), args.video)


if __name__ == "__main__":
    main()
