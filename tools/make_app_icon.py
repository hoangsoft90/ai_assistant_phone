#!/usr/bin/env python3
"""Sinh bộ icon launcher cho app (adaptive icon Android + PNG legacy).

Vẽ bằng Pillow từ toạ độ thuần (không ảnh gốc), chạy lại bất cứ lúc nào để tái tạo:
    python3 tools/make_app_icon.py

Thiết kế (concept đã chốt với user 2026-09-21):
- Nền: gradient chéo teal (khớp `ColorScheme.fromSeed(Colors.teal)` của app).
- Hình: bong bóng hội thoại TRẮNG + đuôi, bên trong là sóng âm 5 thanh màu teal —
  "nghe giọng nói → gợi ý câu nói" đọc được trong một cái liếc (ràng buộc design-system.md).

Hình học (quan trọng — đã tính toán, không cảm tính):
- Adaptive icon: canvas 108dp, launcher chỉ hiện **72dp giữa**, vùng an toàn nội dung là
  **đường tròn 66dp** giữa. Toàn bộ bong bóng + đuôi phải nằm trong đường tròn đó, nếu không
  launcher mặt nạ tròn (Pixel/Samsung) sẽ cắt mất đuôi → icon mất ý nghĩa. Toạ độ dưới đây tính
  theo đơn vị dp với tâm (54,54): điểm xa nhất của nội dung là chóp đuôi, cách tâm ~30dp < 33dp ✅.
- Legacy PNG (launcher cũ): dùng layout RIÊNG với nội dung phóng ~1.32× để lấp đầy ô vuông bo góc
  (nếu dùng nguyên layout adaptive thì icon trông quá nhỏ trong launcher cũ).

Chia layer adaptive (quan trọng — Android bắt buộc):
- **background** = `ic_launcher_background.png` (gradient, layer riêng).
- **foreground** = `ic_launcher_foreground.png` **NỀN TRONG SUỐT**, chỉ chứa bong bóng + sóng âm.
  Foreground đục sẽ che mất background ⇒ mặt nạ/parallax của launcher vô hiệu và layer
  background thành file chết. Đây là lỗi đã sửa ngày 2026-09-21.

Đầu ra:
- res/mipmap-anydpi-v26/ic_launcher.xml + ic_launcher_round.xml (adaptive, minSdk 26).
- res/mipmap-{mdpi,xxxhdpi}/ic_launcher_foreground.png (trong suốt) + background xxxhdpi.
- res/mipmap-*/ic_launcher.png + ic_launcher_round.png (legacy đủ dpi, chuẩn 48dp).
- icon_preview.png (gốc repo, gitignore) — 4 ô: legacy vuông/tròn + adaptive vuông bo/tròn.
"""

from __future__ import annotations

import os
import sys

from PIL import Image, ImageDraw

RES = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "android", "app", "src", "main", "res",
)
LEGACY_DPI = {  # Chuẩn 48dp launcher icon.
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}
LEGACY_MASTER = 1024  # Bức vẽ legacy master rồi thu nhỏ.
LEGACY_SCALE = 1.32   # Nội dung legacy phóng lên so với layout adaptive (lấp đầy vuông).

# Bảng màu (hex, không # để tiện format XML):
TEAL_DARK = "00796B"   # Góc trên trái gradient.
TEAL_MAIN = "00897B"   # Giữa gradient (gần Colors.teal của Flutter).
TEAL_LIGHT = "26A69A"  # Góc dưới phải gradient.
WHITE = "FFFFFF"
# Sóng âm dùng teal đậm hơn để tương phản tốt trên bong bóng trắng.
BAR_COLOR = "00695C"


def hex_rgb(h: str) -> tuple:
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def smooth_gradient(size: int) -> Image.Image:
    """Gradient chéo mượt: vẽ 256px rồi resize (nhanh, không kẻ sọc).

    Trên-trái TEAL_DARK → dưới-phải TEAL_LIGHT.
    """
    c0, c1 = hex_rgb(TEAL_DARK), hex_rgb(TEAL_LIGHT)
    small = Image.new("RGB", (256, 256))
    px = small.load()
    for y in range(256):
        for x in range(256):
            t = (x + y) / 510
            px[x, y] = tuple(round(c0[i] + (c1[i] - c0[i]) * t) for i in range(3))
    return small.resize((size, size), Image.LANCZOS)


def draw_content(size: int, scale: float = 1.0) -> Image.Image:
    """Bong bóng hội thoại trắng + đuôi + sóng âm 5 thanh, nền trong suốt.

    Toạ độ gốc tính theo dp trên canvas 108dp, tâm icon (54,54):
    - Bong bóng 46×32dp, tâm (54,50) (lệch lên chừa chỗ đuôi), bo góc 13.5dp.
    - Đuôi: tam giác dưới-trái, chóp ở (29,71) — điểm xa nhất của nội dung so với tâm,
      ~30.2dp < 33dp (bán kính vùng an toàn adaptive 66dp) khi scale=1.0.
    - Sóng âm 5 thanh thấp-cao-thấp đối xứng giữa bong bóng.

    `scale` phóng toàn bộ nội dung quanh tâm icon (legacy dùng 1.32).
    """
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    u = size / 108.0  # 1dp = u px
    cx, cy = 54 * u, 54 * u

    def P(x: float, y: float) -> tuple:
        """Điểm (x,y) theo dp → px, phóng `scale` quanh tâm icon."""
        return (cx + (x * u - cx) * scale, cy + (y * u - cy) * scale)

    white = hex_rgb(WHITE) + (255,)
    bar = hex_rgb(BAR_COLOR) + (255,)

    # --- Bong bóng chính (rounded rect 46×32dp, tâm (54,50), bo góc 13.5dp) ---
    left, top = 54 - 23, 50 - 16
    right, bottom = 54 + 23, 50 + 16
    d.rounded_rectangle(
        [P(left, top), P(right, bottom)],
        radius=13.5 * u * scale,
        fill=white,
    )

    # --- Đuôi bong bóng (dưới-trái, trỏ về "người nghe") ---
    tail = [P(36, 62), P(29, 71), P(47, 63.5)]
    d.polygon(tail, fill=white)

    # --- Sóng âm 5 thanh giữa bong bóng ---
    bars = [0.30, 0.52, 0.72, 0.52, 0.30]  # tỉ lệ chiều cao so với chiều cao bong bóng
    bar_w = 3.9 * u * scale
    gap = 2.85 * u * scale
    total = len(bars) * bar_w + (len(bars) - 1) * gap
    x = cx - total / 2
    center_y = P(54, 50)[1]
    bubble_h = 32 * u * scale
    for h_ratio in bars:
        h = bubble_h * h_ratio
        d.rounded_rectangle(
            [x, center_y - h / 2, x + bar_w, center_y + h / 2],
            radius=bar_w / 2,
            fill=bar,
        )
        x += bar_w + gap

    return im


def adaptive_foreground() -> Image.Image:
    """Foreground adaptive 432px (108dp @xxxhdpi): CHỈ nội dung, nền trong suốt.

    Không vẽ gradient ở đây — nền là layer `ic_launcher_background` riêng, nếu không
    launcher không áp được mặt nạ/parallax và background trở thành file chết.
    """
    return draw_content(432, scale=1.0)


def legacy_round_icon() -> Image.Image:
    """Legacy round PNG: nội dung scale lớn + cắt tròn (launcher cũ cấu hình hình tròn)."""
    im = smooth_gradient(LEGACY_MASTER).convert("RGBA")
    im.alpha_composite(draw_content(LEGACY_MASTER, scale=LEGACY_SCALE))
    mask = Image.new("L", (LEGACY_MASTER, LEGACY_MASTER), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, LEGACY_MASTER - 1, LEGACY_MASTER - 1], fill=255)
    out = Image.new("RGBA", (LEGACY_MASTER, LEGACY_MASTER), (0, 0, 0, 0))
    out.paste(im, (0, 0), mask)
    return out


def legacy_square_icon() -> Image.Image:
    """Legacy square PNG: gradient + nội dung lớn, bo góc nhẹ (launcher cũ hình vuông bo)."""
    im = smooth_gradient(LEGACY_MASTER).convert("RGBA")
    im.alpha_composite(draw_content(LEGACY_MASTER, scale=LEGACY_SCALE))
    mask = Image.new("L", (LEGACY_MASTER, LEGACY_MASTER), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, LEGACY_MASTER - 1, LEGACY_MASTER - 1],
        radius=int(LEGACY_MASTER * 0.18),
        fill=255,
    )
    out = Image.new("RGBA", (LEGACY_MASTER, LEGACY_MASTER), (0, 0, 0, 0))
    out.paste(im, (0, 0), mask)
    return out


def write_xml_files() -> None:
    anydpi = os.path.join(RES, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        with open(os.path.join(anydpi, name), "w") as f:
            f.write(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
                '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
                '</adaptive-icon>\n'
            )

def compose_adaptive(mask: str, size: int = 512) -> Image.Image:
    """Ghép đúng như launcher: background PNG + foreground trong suốt + mặt nạ.

    Dùng để render preview (không phải file cài vào app). `mask` = "circle" | "squircle".
    """
    bg = smooth_gradient(size).convert("RGBA")
    bg.alpha_composite(draw_content(size, scale=1.0))
    m = Image.new("L", (size, size), 0)
    if mask == "circle":
        ImageDraw.Draw(m).ellipse([0, 0, size - 1, size - 1], fill=255)
    else:
        ImageDraw.Draw(m).rounded_rectangle(
            [0, 0, size - 1, size - 1], radius=int(size * 0.22), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(bg, (0, 0), m)
    return out


def main() -> int:
    # Adaptive: foreground đặt mdpi (108px) + xxxhdpi (432px) — Android tự chọn/scale.
    fg = adaptive_foreground()
    for dpi, side in (("mdpi", 108), ("xxxhdpi", 432)):
        folder = os.path.join(RES, f"mipmap-{dpi}")
        os.makedirs(folder, exist_ok=True)
        fg.resize((side, side), Image.LANCZOS).save(
            os.path.join(folder, "ic_launcher_foreground.png"))
    # Background gradient chỉ cần 1 bản (xxxhdpi).
    smooth_gradient(432).save(
        os.path.join(RES, "mipmap-xxxhdpi", "ic_launcher_background.png"))

    # Legacy PNG theo dpi: ic_launcher (vuông bo) + ic_launcher_round (tròn).
    square = legacy_square_icon()
    round_icon = legacy_round_icon()
    for dpi, side in LEGACY_DPI.items():
        folder = os.path.join(RES, f"mipmap-{dpi}")
        os.makedirs(folder, exist_ok=True)
        square.resize((side, side), Image.LANCZOS).save(
            os.path.join(folder, "ic_launcher.png"))
        round_icon.resize((side, side), Image.LANCZOS).save(
            os.path.join(folder, "ic_launcher_round.png"))

    write_xml_files()

    # Preview ở gốc repo (gitignore): 4 ô = legacy vuông/tròn + adaptive squircle/circle.
    cell = 512
    preview = Image.new("RGB", (cell * 2, cell * 2), (238, 238, 238))
    panels = [
        square.resize((cell, cell), Image.LANCZOS),
        round_icon.resize((cell, cell), Image.LANCZOS),
        compose_adaptive("squircle", cell),
        compose_adaptive("circle", cell),
    ]
    for i, panel in enumerate(panels):
        preview.paste(panel, ((i % 2) * cell, (i // 2) * cell), panel)
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    preview.save(os.path.join(repo_root, "icon_preview.png"))
    print("OK — đã sinh icon vào", RES)
    return 0


if __name__ == "__main__":
    sys.exit(main())
