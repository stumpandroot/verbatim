#!/usr/bin/env python3
"""Generates Verbatim's synthetic bench clips with macOS `say`.

Usage: make_clips.py <out-dir> [--fixtures clips.json]

For each clip in clips.json it writes <id>.wav (16 kHz, mono, 16-bit) and <id>.txt (the reference text),
then copies clips.json into <out-dir> with the voices that were used. Silence, noise, babble, and quiet
variants are made here in Python with a fixed random seed, so the clips are the same on every run of the
same macOS version (no sox or ffmpeg needed). Needs macOS (`say`, `afconvert`).
"""
import array
import json
import math
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

RATE = 16000
PRIMARY = ["Samantha", "Alex", "Ava", "Allison", "Tom"]
SECONDARY = ["Daniel", "Karen", "Moira", "Tessa", "Rishi", "Fred"]


def log(msg):
    print(msg, flush=True)


def voices():
    """Installed voices as (name, locale)."""
    try:
        out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True, timeout=30).stdout
    except Exception as e:  # noqa: BLE001
        log(f"say -v ? failed: {e}")
        return []
    found = []
    for line in out.splitlines():
        m = re.match(r"^(.+?)\s+([a-z]{2,3}[_-][A-Za-z0-9]+)\s+#", line)
        if m:
            found.append((m.group(1).strip(), m.group(2)))
    return found


def pick(installed, preferred, avoid=None):
    names = [n for n, _ in installed]
    for p in preferred:
        if p in names and p != avoid:
            return p
    for n, loc in installed:
        if loc.replace("-", "_").startswith("en_") and n != avoid:
            return n
    return None


# --- WAV I/O (16-bit PCM; handles WAVE_FORMAT_EXTENSIBLE and extra chunks such as Apple's FLLR) ---

def read_wav(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError(f"{path}: not a WAVE file")
    pos, fmt, pcm = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            tag, channels, rate, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            fmt = (tag, channels, rate, bits)
        elif cid == b"data":
            pcm = body
        pos += 8 + size + (size & 1)
    if fmt is None or pcm is None:
        raise ValueError(f"{path}: missing fmt or data chunk")
    tag, channels, rate, bits = fmt
    if bits != 16 or tag not in (1, 0xFFFE):
        raise ValueError(f"{path}: expected 16-bit PCM, got tag={tag} bits={bits}")
    samples = array.array("h")
    samples.frombytes(pcm[: len(pcm) - (len(pcm) % 2)])
    if sys.byteorder != "little":
        samples.byteswap()
    if channels > 1:
        samples = array.array("h", samples[::channels])
    return [s / 32768.0 for s in samples], rate


def write_wav(path, floats, rate=RATE):
    ints = array.array("h", (max(-32768, min(32767, int(round(x * 32767)))) for x in floats))
    if sys.byteorder != "little":
        ints.byteswap()
    pcm = ints.tobytes()
    header = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    header += b"data" + struct.pack("<I", len(pcm))
    with open(path, "wb") as f:
        f.write(header + pcm)


def rms(xs):
    voiced = [x for x in xs if abs(x) > 1e-4] or xs
    return math.sqrt(sum(x * x for x in voiced) / max(1, len(voiced)))


# --- Speech ---

def speak(text, voice, tmp, name):
    """Speaks text into a 16 kHz mono WAV and returns (samples, rate)."""
    raw = os.path.join(tmp, name + "-say.wav")
    cmd = ["say", "-o", raw, "--file-format=WAVE", "--data-format=LEI16@16000"]
    if voice:
        cmd += ["-v", voice]
    subprocess.run(cmd + [text], check=True, timeout=120)
    out = os.path.join(tmp, name + ".wav")
    # afconvert normalizes the container and channel count; fall back to say's own file if it fails.
    r = subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", raw, out], capture_output=True, timeout=60)
    path = out if r.returncode == 0 and os.path.exists(out) else raw
    return read_wav(path)


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    out_dir = os.path.abspath(args[0])
    fixtures = os.path.join(os.path.dirname(os.path.abspath(__file__)), "clips.json")
    if "--fixtures" in args:
        fixtures = os.path.abspath(args[args.index("--fixtures") + 1])
    if shutil.which("say") is None:
        log("`say` is not available: run this on macOS.")
        return 1
    with open(fixtures, encoding="utf-8") as f:
        suite = json.load(f)
    os.makedirs(out_dir, exist_ok=True)

    installed = voices()
    primary = pick(installed, PRIMARY)
    secondary = pick(installed, SECONDARY, avoid=primary) or primary
    log(f"{len(installed)} voices installed; primary={primary or 'system default'} secondary={secondary or 'system default'}")

    made, skipped = [], []
    with tempfile.TemporaryDirectory() as tmp:
        for clip in suite["clips"]:
            cid = clip["id"]
            gen = clip.get("gen") or {}
            kind = gen.get("type", "speech")
            voice = secondary if clip.get("voice") == "secondary" else primary
            spoken = clip.get("say") or clip.get("text", "")
            try:
                if kind == "silence":
                    samples, rate = [0.0] * int(RATE * float(gen.get("seconds", 3))), RATE
                else:
                    samples, rate = speak(spoken, voice, tmp, cid)
                    if kind == "lead-silence":
                        samples = [0.0] * int(rate * float(gen.get("seconds", 1))) + samples
                    elif kind == "white-noise":
                        rng = random.Random(zlib.crc32(cid.encode()))
                        level = rms(samples) / (10 ** (float(gen.get("snrDb", 10)) / 20))
                        pad = [0.0] * int(rate * 0.3)
                        samples = pad + samples + pad
                        samples = [x + rng.gauss(0.0, level) for x in samples]
                    elif kind == "babble":
                        other, _ = speak(gen.get("babbleText", "background voices"), secondary if voice == primary else primary, tmp, cid + "-babble")
                        if other:
                            gain = rms(samples) / (10 ** (float(gen.get("snrDb", 8)) / 20)) / max(rms(other), 1e-6)
                            samples = [x + other[i % len(other)] * gain for i, x in enumerate(samples)]
                    elif kind == "quiet":
                        g = 10 ** (float(gen.get("gainDb", -24)) / 20)
                        samples = [x * g for x in samples]
                    elif kind != "speech":
                        raise ValueError(f"unknown gen type {kind}")
                peak = max((abs(x) for x in samples), default=0)
                if peak > 0.99:  # mixing can clip; scale down rather than distort
                    samples = [x * 0.99 / peak for x in samples]
                write_wav(os.path.join(out_dir, cid + ".wav"), samples, rate)
                with open(os.path.join(out_dir, cid + ".txt"), "w", encoding="utf-8") as f:
                    f.write(clip.get("text", ""))
                made.append(cid)
                log(f"{cid}: {len(samples) / rate:.2f}s {kind} voice={voice or 'default'}")
            except Exception as e:  # noqa: BLE001
                skipped.append(cid)
                log(f"{cid}: skipped ({e})")

    suite["voices"] = {"primary": primary or "system default", "secondary": secondary or "system default"}
    suite["generated"] = made
    suite["skipped"] = skipped
    with open(os.path.join(out_dir, "clips.json"), "w", encoding="utf-8") as f:
        json.dump(suite, f, indent=2)
    log(f"made {len(made)} clips in {out_dir}; skipped {len(skipped)}")
    return 0 if made else 1


if __name__ == "__main__":
    sys.exit(main())
