"""Regenerate TableSideCY launcher icons from the committed brand masters.

Requires Pillow (`python -m pip install pillow`). The generated platform files
are committed so normal Flutter builds do not need Python or Pillow.
"""

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "assets" / "tablesidecy-app-icon.png"
FOREGROUND = ROOT / "assets" / "tablesidecy-app-icon-foreground.png"


def resized(image: Image.Image, size: int, *, alpha: bool = False) -> Image.Image:
    mode = "RGBA" if alpha else "RGB"
    return image.convert(mode).resize((size, size), Image.Resampling.LANCZOS)


def save_png(image: Image.Image, path: Path, size: int, *, alpha: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    resized(image, size, alpha=alpha).save(path, optimize=True)


def main() -> None:
    master = Image.open(MASTER)
    foreground = Image.open(FOREGROUND)

    android_legacy = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    android_foreground = {
        "drawable-mdpi": 108,
        "drawable-hdpi": 162,
        "drawable-xhdpi": 216,
        "drawable-xxhdpi": 324,
        "drawable-xxxhdpi": 432,
    }
    android_res = ROOT / "android" / "app" / "src" / "main" / "res"
    for folder, size in android_legacy.items():
        save_png(master, android_res / folder / "ic_launcher.png", size)
    for folder, size in android_foreground.items():
        save_png(
            foreground,
            android_res / folder / "ic_launcher_foreground.png",
            size,
            alpha=True,
        )

    ios_sizes = {
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    ios_dir = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for filename, size in ios_sizes.items():
        save_png(master, ios_dir / filename, size)

    web_dir = ROOT / "web"
    save_png(master, web_dir / "favicon.png", 32)
    save_png(master, web_dir / "icons" / "Icon-192.png", 192)
    save_png(master, web_dir / "icons" / "Icon-512.png", 512)
    save_png(master, web_dir / "icons" / "Icon-maskable-192.png", 192)
    save_png(master, web_dir / "icons" / "Icon-maskable-512.png", 512)

    windows_icon = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    windows_icon.parent.mkdir(parents=True, exist_ok=True)
    master.convert("RGBA").save(
        windows_icon,
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )

    store_dir = ROOT / "assets" / "store"
    save_png(master, store_dir / "apple-app-store-icon-1024.png", 1024)
    save_png(master, store_dir / "google-play-icon-512.png", 512)


if __name__ == "__main__":
    main()
