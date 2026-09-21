#!/usr/bin/env python3
"""Tải mẫu audio tiếng Việt thật từ FLEURS (google/fleurs, config vi_vn) + transcript ground-truth.

Vì sao cần script này:
- FLEURS phát audio dạng WAV float32 32-bit, whisper.cpp / Vosk chỉ đọc PCM 16-bit.
- Có ground-truth để đo WER thay vì "nghe rồi đoán" -> số liệu so sánh PhoWhisper vs Vosk
  ở P0 là số liệu thật, không phải cảm tính.

Chỉ dùng thư viện chuẩn (không cần venv, không cần ffmpeg/sox).

Cách dùng:
    python3 tools/fetch_test_audio.py --out /tmp/p0spike/fleurs_vi --count 10
Kết quả trong <out>/:
    vi_000.wav ... (16kHz, mono, PCM16)
    transcripts.tsv   # <tên file>\t<transcript chuẩn>
"""

import argparse
import array
import json
import os
import struct
import sys
import urllib.request
import wave

ROWS_API = "https://datasets-server.huggingface.co/rows"
DATASET = "google/fleurs"
CONFIG = "vi_vn"


def fetch_rows(split: str, offset: int, length: int) -> dict:
    url = (
        f"{ROWS_API}?dataset={urllib.parse.quote(DATASET, safe='')}"
        f"&config={CONFIG}&split={split}&offset={offset}&length={length}"
    )
    with urllib.request.urlopen(url, timeout=60) as r:
        data = json.load(r)
    if "error" in data:
        sys.exit(f"datasets-server trả lỗi: {data['error']}")
    return data


def read_wav_any(path: str):
    """Đọc WAV, chấp nhận cả PCM 16-bit lẫn IEEE float32 (format tag 3)."""
    with open(path, "rb") as f:
        raw = f.read()

    if raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        sys.exit(f"{path}: không phải file WAV")

    pos, fmt, data = 12, None, None
    while pos + 8 <= len(raw):
        chunk_id = raw[pos : pos + 4]
        (size,) = struct.unpack("<I", raw[pos + 4 : pos + 8])
        body = raw[pos + 8 : pos + 8 + size]
        if chunk_id == b"fmt ":
            fmt = struct.unpack("<HHIIHH", body[:16])
        elif chunk_id == b"data":
            data = body
        pos += 8 + size + (size & 1)

    if fmt is None or data is None:
        sys.exit(f"{path}: thiếu chunk fmt/data")

    audio_format, channels, sample_rate, _, _, bits = fmt
    if audio_format == 3:  # IEEE float
        if bits != 32:
            sys.exit(f"{path}: float {bits}-bit chưa hỗ trợ")
        samples = array.array("f")
        samples.frombytes(data[: len(data) - (len(data) % 4)])
    elif audio_format == 1:  # PCM int
        if bits != 16:
            sys.exit(f"{path}: PCM {bits}-bit chưa hỗ trợ")
        samples = array.array("h")
        samples.frombytes(data[: len(data) - (len(data) % 2)])
    else:
        sys.exit(f"{path}: format tag {audio_format} chưa hỗ trợ")

    if channels > 1:  # trộn về mono
        mono = array.array(samples.typecode)
        for i in range(0, len(samples) - channels + 1, channels):
            mono.append(sum(samples[i : i + channels]) // channels)
        samples = mono

    return samples, sample_rate, audio_format


def to_pcm16_mono_16k(samples, sample_rate: int, audio_format: int):
    """Đưa về 16kHz mono PCM16. Resample bằng nội suy tuyến tính (đủ cho mục đích test)."""
    if audio_format == 3:  # float [-1,1] -> int16
        pcm = array.array("h", (max(-32768, min(32767, int(s * 32767))) for s in samples))
    else:
        pcm = samples

    if sample_rate == 16000:
        return pcm

    ratio = 16000 / sample_rate
    n_out = int(len(pcm) * ratio)
    out = array.array("h", [0]) * n_out
    for i in range(n_out):
        src = i / ratio
        i0 = int(src)
        i1 = min(i0 + 1, len(pcm) - 1)
        frac = src - i0
        out[i] = int(pcm[i0] * (1 - frac) + pcm[i1] * frac)
    return out


def write_pcm16(path: str, samples, sample_rate: int = 16000):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(samples.tobytes())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="thư mục đích")
    ap.add_argument("--count", type=int, default=10, help="số mẫu cần lấy")
    ap.add_argument("--offset", type=int, default=0, help="bỏ qua N mẫu đầu")
    ap.add_argument("--split", default="validation")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    rows = fetch_rows(args.split, args.offset, args.count)

    tsv_path = os.path.join(args.out, "transcripts.tsv")
    done = 0
    with open(tsv_path, "w", encoding="utf-8") as tsv:
        for r in rows["rows"]:
            idx = r["row_idx"]
            row = r["row"]
            text = (row.get("transcription") or row.get("raw_transcription") or "").strip()
            src = row["audio"][0]["src"]
            wav_name = f"vi_{idx:03d}.wav"
            wav_path = os.path.join(args.out, wav_name)
            raw_path = wav_path + ".raw"

            urllib.request.urlretrieve(src, raw_path)
            samples, sr, fmt = read_wav_any(raw_path)
            pcm = to_pcm16_mono_16k(samples, sr, fmt)
            write_pcm16(wav_path, pcm)
            os.remove(raw_path)

            dur = len(pcm) / 16000
            tsv.write(f"{wav_name}\t{text}\n")
            print(f"{wav_name}  {dur:5.2f}s  sr_in={sr}  {text[:70]}")
            done += 1

    print(f"\nĐã lấy {done} mẫu -> {args.out} ({tsv_path})")


if __name__ == "__main__":
    main()
