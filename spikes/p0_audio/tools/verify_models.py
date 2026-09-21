#!/usr/bin/env python3
"""Đo WER + độ trễ của model GGML trên MÁY DEV (không phải điện thoại) với FLEURS vi_vn.

Mục đích: xác nhận file model convert ra dùng được thật (load, decode ra tiếng Việt đúng),
thay vì chỉ kiểm tra "file tồn tại". Số liệu ở đây KHÔNG thay thế số liệu on-device của P0
(CPU điện thoại chậm hơn nhiều, và P0 phải đo trên chính giọng người dùng).

Cách dùng:
    tools/verify_models.py --workdir /tmp/p0spike --audio /tmp/p0spike/fleurs_vi

Kết quả: bảng WER/latency in ra stdout và file <workdir>/verify_report.json
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

WORD_RE = re.compile(r"[^\w\s]", re.UNICODE)


def normalize(text: str) -> str:
    return WORD_RE.sub(" ", text.lower()).split()


def wer(ref: str, hyp: str) -> float:
    """Word error rate = (S+D+I)/N, tính bằng DP."""
    r, h = normalize(ref), normalize(hyp)
    if not r:
        return 0.0 if not h else 1.0
    prev = list(range(len(h) + 1))
    for i, rw in enumerate(r, start=1):
        cur = [i] + [0] * len(h)
        for j, hw in enumerate(h, start=1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (rw != hw))
        prev = cur
    return prev[len(h)] / len(r)


def load_ground_truth(audio_dir: str):
    tsv = os.path.join(audio_dir, "transcripts.tsv")
    if not os.path.isfile(tsv):
        sys.exit(f"Không thấy {tsv}. Chạy trước: tools/fetch_test_audio.py --out {audio_dir}")
    pairs = []
    with open(tsv, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            name, _, text = line.partition("\t")
            wav = os.path.join(audio_dir, name)
            if os.path.isfile(wav):
                pairs.append((wav, text))
    return pairs


def transcribe(cli: str, model: str, wav: str, threads: int):
    """Chạy whisper-cli, trả về (text, thời gian xử lý giây, số giây audio)."""
    with open(wav, "rb") as f:
        import wave

        with wave.open(f) as w:
            dur = w.getnframes() / w.getframerate()

    t0 = time.monotonic()
    out = subprocess.run(
        [cli, "-m", model, "-f", wav, "-l", "vi", "-nt", "-t", str(threads), "-np"],
        capture_output=True,
        text=True,
    )
    elapsed = time.monotonic() - t0
    if out.returncode != 0:
        sys.exit(f"whisper-cli lỗi ({model}):\n{out.stderr[-2000:]}")

    lines = [l.strip() for l in out.stdout.splitlines() if l.strip()]
    return " ".join(lines), elapsed, dur


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workdir", default="/tmp/p0spike")
    ap.add_argument("--audio", default=None, help="thư mục chứa wav + transcripts.tsv")
    ap.add_argument("--threads", type=int, default=os.cpu_count() or 4)
    ap.add_argument(
        "--models",
        default=None,
        help="danh sách model cách nhau bởi dấu phẩy (mặc định: quét <workdir>/models/*.bin)",
    )
    args = ap.parse_args()

    audio_dir = args.audio or os.path.join(args.workdir, "fleurs_vi")
    cli = os.path.join(args.workdir, "whisper.cpp/build/bin/whisper-cli")
    if not os.path.isfile(cli):
        sys.exit(f"Không thấy whisper-cli ở {cli}. Chạy trước: tools/convert_phowhisper.sh")

    if args.models:
        models = [m.strip() for m in args.models.split(",") if m.strip()]
    else:
        mdir = os.path.join(args.workdir, "models")
        models = sorted(
            os.path.join(mdir, f) for f in os.listdir(mdir) if f.endswith(".bin")
        )

    pairs = load_ground_truth(audio_dir)
    if not pairs:
        sys.exit(f"Không có mẫu audio nào trong {audio_dir}")

    print(f"Thiết bị: dev host, {args.threads} threads | {len(models)} model | {len(pairs)} mẫu\n")

    report = {"host_threads": args.threads, "samples": len(pairs), "models": {}}
    for model in models:
        name = os.path.basename(model)
        size_mb = os.path.getsize(model) / 1e6
        wers, rtf_list, latencies = [], [], []
        print(f"--- {name} ({size_mb:.0f} MB) ---")
        for wav, ref in pairs:
            hyp, elapsed, dur = transcribe(cli, model, wav, args.threads)
            w = wer(ref, hyp)
            wers.append(w)
            rtf_list.append(elapsed / dur)
            latencies.append(elapsed)
            print(f"  {os.path.basename(wav)}  WER={w * 100:5.1f}%  {elapsed:5.1f}s/{dur:4.1f}s audio  RTF={elapsed / dur:.2f}")
            print(f"    ref: {ref[:90]}")
            print(f"    hyp: {hyp[:90]}")

        avg_wer = sum(wers) / len(wers)
        avg_rtf = sum(rtf_list) / len(rtf_list)
        report["models"][name] = {
            "size_mb": round(size_mb, 1),
            "avg_wer_pct": round(avg_wer * 100, 2),
            "avg_rtf": round(avg_rtf, 3),
            "avg_latency_s_per_clip": round(sum(latencies) / len(latencies), 2),
            "per_sample_wer_pct": [round(w * 100, 1) for w in wers],
        }
        print(f"  => WER trung bình {avg_wer * 100:.1f}% | RTF {avg_rtf:.2f} (chunk 3s -> ~{avg_rtf * 3:.1f}s xử lý)\n")

    out_path = os.path.join(args.workdir, "verify_report.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    print(f"Đã ghi {out_path}")


if __name__ == "__main__":
    main()
