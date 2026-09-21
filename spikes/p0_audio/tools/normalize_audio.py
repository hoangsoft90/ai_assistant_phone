#!/usr/bin/env python3
"""Chuẩn hoá (peak-normalize) các file WAV về một mức âm lượng cố định.

Vì sao cần: đo thực tế cho thấy Vosk model nhỏ trả về RỖNG khi audio nhỏ tiếng
(peak ~500-800/32767), chỉ đọc được sau khi khuếch đại. Tình huống thật của app là mic
điện thoại để xa người nói -> mức thu thấp. Script này tạo bộ mẫu "đã chuẩn hoá" để so sánh
công bằng giữa các engine, và cũng dùng để kiểm chứng giả thuyết "engine X yếu vì âm lượng".

Cách dùng:
    python3 tools/normalize_audio.py --in <dir nguồn> --out <dir đích> [--peak 0.5]
"""

import argparse
import array
import os
import shutil
import wave


def normalize_file(src: str, dst: str, target_peak: float):
    with wave.open(src, "rb") as w:
        if w.getsampwidth() != 2:
            raise SystemExit(f"{src}: chỉ hỗ trợ PCM16")
        sr, ch = w.getframerate(), w.getnchannels()
        samples = array.array("h")
        samples.frombytes(w.readframes(w.getnframes()))

    peak = max((abs(s) for s in samples), default=0) or 1
    gain = (target_peak * 32767) / peak
    out = array.array("h", (max(-32768, min(32767, int(s * gain))) for s in samples))

    with wave.open(dst, "wb") as w:
        w.setnchannels(ch)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(out.tobytes())
    return gain


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src_dir", required=True)
    ap.add_argument("--out", dest="dst_dir", required=True)
    ap.add_argument("--peak", type=float, default=0.5, help="biên độ đỉnh đích (0-1)")
    args = ap.parse_args()

    os.makedirs(args.dst_dir, exist_ok=True)
    n = 0
    for name in sorted(os.listdir(args.src_dir)):
        if not name.endswith(".wav"):
            continue
        gain = normalize_file(
            os.path.join(args.src_dir, name), os.path.join(args.dst_dir, name), args.peak
        )
        print(f"{name}  gain x{gain:.1f}")
        n += 1

    # giữ nguyên ground-truth để đo WER trên bộ đã chuẩn hoá
    tsv = os.path.join(args.src_dir, "transcripts.tsv")
    if os.path.isfile(tsv):
        shutil.copy(tsv, os.path.join(args.dst_dir, "transcripts.tsv"))

    print(f"\nĐã chuẩn hoá {n} file -> {args.dst_dir}")


if __name__ == "__main__":
    main()
