#!/usr/bin/env python3
"""Đo WER + độ trễ của model Vosk tiếng Việt trên MÁY DEV, cùng bộ mẫu FLEURS với PhoWhisper.

Cần: pip install vosk (trong cùng venv dùng để convert).
Cách dùng:
    tools/verify_vosk.py --workdir /tmp/p0spike --model /tmp/p0spike/models/vosk-model-small-vn-0.4
"""

import argparse
import json
import os
import sys
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verify_models import load_ground_truth, wer  # dùng chung cách tính WER để so sánh công bằng


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workdir", default="/tmp/p0spike")
    ap.add_argument("--model", required=True, help="thư mục model Vosk đã giải nén")
    ap.add_argument("--audio", default=None)
    args = ap.parse_args()

    try:
        from vosk import KaldiRecognizer, Model, SetLogLevel
    except ImportError:
        sys.exit("Chưa có vosk. Chạy: <venv>/bin/pip install vosk")

    SetLogLevel(-1)  # tắt log ồn của Kaldi

    audio_dir = args.audio or os.path.join(args.workdir, "fleurs_vi")
    pairs = load_ground_truth(audio_dir)
    if not pairs:
        sys.exit(f"Không có mẫu audio nào trong {audio_dir}")

    t0 = time.monotonic()
    model = Model(args.model)
    load_time = time.monotonic() - t0

    print(f"Vosk model: {os.path.basename(args.model)} | load {load_time:.2f}s | {len(pairs)} mẫu\n")
    wers, rtfs = [], []
    for wav, ref in pairs:
        with wave.open(wav, "rb") as w:
            if w.getframerate() != 16000:
                sys.exit(f"{wav}: cần 16kHz, đang là {w.getframerate()}")
            rec = KaldiRecognizer(model, w.getframerate())
            t0 = time.monotonic()
            while True:
                data = w.readframes(4000)
                if not data:
                    break
                rec.AcceptWaveform(data)
            hyp = json.loads(rec.FinalResult()).get("text", "")
            elapsed = time.monotonic() - t0

        w_ = wer(ref, hyp)
        rtfs.append(elapsed / (w.getnframes() / w.getframerate()))
        wers.append(w_)
        print(f"  {os.path.basename(wav)}  WER={w_ * 100:5.1f}%  {elapsed:5.2f}s  RTF={rtfs[-1]:.3f}")
        print(f"    hyp: {hyp[:90]}")

    result = {
        "model": os.path.basename(args.model),
        "model_load_s": round(load_time, 2),
        "avg_wer_pct": round(sum(wers) / len(wers) * 100, 2),
        "avg_rtf": round(sum(rtfs) / len(rtfs), 3),
        "per_sample_wer_pct": [round(w * 100, 1) for w in wers],
    }
    out = os.path.join(args.workdir, "verify_vosk_report.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(f"\n=> WER trung bình {result['avg_wer_pct']}% | RTF {result['avg_rtf']} | ghi {out}")


if __name__ == "__main__":
    main()
