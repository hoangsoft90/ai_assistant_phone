#!/usr/bin/env bash
# Convert PhoWhisper (HuggingFace) -> GGML f16 -> quantize q5_0, dùng whisper.cpp.
#
# Đây là pipeline chính thức cho P0 (Task 1.1) và sẽ được P1C dùng lại để sinh model
# đưa vào assets/models/ của app thật. Chạy trên máy dev, KHÔNG chạy trên điện thoại.
#
# Cách dùng:
#   tools/convert_phowhisper.sh [WORKDIR]        # mặc định WORKDIR=/tmp/p0spike
#
# Kết quả cuối (copy sang máy/điện thoại tuỳ ý):
#   $WORKDIR/models/ggml-phowhisper-tiny-q5_0.bin
#   $WORKDIR/models/ggml-phowhisper-base-q5_0.bin
#
# Yêu cầu: python3, git, curl, cmake, gcc/g++.
# CẢNH BÁO DUNG LƯỢNG: cần ~2.5-3GB đĩa trống ở WORKDIR (venv torch ~1GB + build whisper.cpp
# + model tạm). KHÔNG nên đặt WORKDIR trong thư mục repo nếu ổ đĩa chật.

set -euo pipefail

WORKDIR="${1:-/tmp/p0spike}"
WHISPER_DIR="$WORKDIR/whisper.cpp"
VENV="$WORKDIR/venv"
MODELS=("PhoWhisper-tiny" "PhoWhisper-base")

mkdir -p "$WORKDIR/models"

# --- 1. Clone whisper.cpp ---------------------------------------------------
if [ ! -d "$WHISPER_DIR" ]; then
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git "$WHISPER_DIR"
fi

# --- 2. Python venv + torch CPU + transformers ------------------------------
# torch CPU-only (--index-url .../whl/cpu) để tránh kéo theo CUDA ~2GB không cần thiết.
if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install --upgrade pip
  "$VENV/bin/pip" -q install torch --index-url https://download.pytorch.org/whl/cpu
  "$VENV/bin/pip" -q install transformers numpy
fi

# --- 3. whisper/assets/mel_filters.npz -------------------------------------
# Script convert cần file này của repo openai/whisper; tải thẳng 1 file thay vì clone cả repo.
WHISPER_REPO="$WORKDIR/whisper_repo"
mkdir -p "$WHISPER_REPO/whisper/assets"
if [ ! -f "$WHISPER_REPO/whisper/assets/mel_filters.npz" ]; then
  curl -sL -o "$WHISPER_REPO/whisper/assets/mel_filters.npz" \
    https://raw.githubusercontent.com/openai/whisper/main/whisper/assets/mel_filters.npz
fi

# --- 4. Build whisper.cpp (cần cho whisper-quantize) ------------------------
if [ ! -x "$WHISPER_DIR/build/bin/whisper-quantize" ]; then
  cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_TESTS=OFF
  cmake --build "$WHISPER_DIR/build" --config Release -j"$(nproc)"
fi

for MODEL in "${MODELS[@]}"; do
  echo "=== $MODEL ==="
  SRC="$WORKDIR/$MODEL"
  OUT="$WORKDIR/out_${MODEL#PhoWhisper-}"
  mkdir -p "$SRC" "$OUT"

  # 4a. Tải trọng số + tokenizer.
  #     LƯU Ý: `hf download --include` trong bản CLI hiện tại BỎ SÓT config.json
  #     (đã gặp thực tế: báo "Fetching 6 files" nhưng thiếu config.json) -> tải riêng bằng curl.
  hf download "vinai/$MODEL" \
    --include "vocab.json" "added_tokens.json" "pytorch_model.bin" \
              "preprocessor_config.json" "generation_config.json" "normalizer.json" \
    --local-dir "$SRC"
  if [ ! -f "$SRC/config.json" ]; then
    curl -sL -o "$SRC/config.json" "https://huggingface.co/vinai/$MODEL/resolve/main/config.json"
  fi

  # 4b. HF (pytorch_model.bin) -> GGML f16
  "$VENV/bin/python" "$WHISPER_DIR/models/convert-h5-to-ggml.py" "$SRC" "$WHISPER_REPO" "$OUT"

  # 4c. Quantize q5_0 (giảm ~60-70% dung lượng, mục tiêu cho mobile)
  "$WHISPER_DIR/build/bin/whisper-quantize" \
    "$OUT/ggml-model.bin" \
    "$WORKDIR/models/ggml-phowhisper-${MODEL#PhoWhisper-}-q5_0.bin" q5_0
done

echo
echo "=== Kết quả ==="
ls -lh "$WORKDIR/models"
echo
echo "Kiểm thử tiếp: tools/verify_models.py --workdir $WORKDIR"
