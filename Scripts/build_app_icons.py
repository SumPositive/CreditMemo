#!/usr/bin/env python3
"""アプリアイコン（プライマリ＋配色プリセット別の Alternate Icon）を SVG から書き出す。

使い方: python3 Scripts/build_app_icons.py
- 元データ: Scripts/AppIcons/AppIcon-<プリセット>.svg（これを編集する）
- 出力: Assets.xcassets/AppIcon/ の各 appiconset の 1024px PNG（App Icon は不透明が必須なのでアルファを外す）
- japaneseEarth はプライマリ AppIcon（AppIcon.appiconset/AppIcon-later-pay.png）に書き出す
- 背景はカルメモ（Calclin/Scripts/AppIcon-source.svg）と同じ小豆色の斜めグラデーション
依存: rsvg-convert（Homebrew librsvg）、Pillow
"""
import glob
import os
import subprocess
import tempfile

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, "Scripts", "AppIcons")
ICON_DIR = os.path.join(ROOT, "CreditMemo", "Resources", "Assets.xcassets", "AppIcon")


def output_path(preset: str) -> str:
    if preset == "japaneseEarth":
        return os.path.join(ICON_DIR, "AppIcon.appiconset", "AppIcon-later-pay.png")
    return os.path.join(ICON_DIR, f"AppIcon-{preset}.appiconset", f"AppIcon-{preset}.png")


def main() -> None:
    for svg in sorted(glob.glob(os.path.join(SRC_DIR, "AppIcon-*.svg"))):
        preset = os.path.basename(svg)[len("AppIcon-"):-len(".svg")]
        dest = output_path(preset)
        if not os.path.isdir(os.path.dirname(dest)):
            raise SystemExit(f"appiconset がありません: {dest}")
        with tempfile.NamedTemporaryFile(suffix=".png") as tmp:
            subprocess.run(["rsvg-convert", "-w", "1024", "-h", "1024", svg, "-o", tmp.name], check=True)
            Image.open(tmp.name).convert("RGB").save(dest)
        print(f"{preset} -> {os.path.relpath(dest, ROOT)}")


if __name__ == "__main__":
    main()
