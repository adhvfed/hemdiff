#!/usr/bin/env python3
"""Regenerate HemDif vector/raster assets with strok; iconutil adds ICNS on macOS."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "exports"


def run(*args):
    subprocess.run(args, check=True)


def main():
    if not shutil.which("strok"):
        raise SystemExit("Install strok and put it on PATH first.")
    OUT.mkdir(exist_ok=True)
    for name in ("fold", "fold-mono", "app-icon"):
        source = str(ROOT / f"{name}.strok")
        run("strok", "-f", source, "audit")
        run("strok", "-f", source, "export", "svg", "--out", str(OUT / f"{name}.svg"))
        for size in (16, 20, 24, 32, 64, 128, 256, 512, 1024):
            run("strok", "-f", source, "export", "png", "--width", str(size),
                "--out", str(OUT / f"{name}-{size}.png"))
        if name == "fold-mono":
            for size in (16, 20, 24, 32):
                run("strok", "-f", source, "export", "png", "--width", str(size),
                    "--color", "#FFFFFF", "--out", str(OUT / f"{name}-white-{size}.png"))
    if shutil.which("iconutil"):
        with tempfile.TemporaryDirectory(prefix="hemdif-icon-") as temporary:
            iconset = Path(temporary) / "HemDif.iconset"
            iconset.mkdir()
            for size in (16, 32, 128, 256, 512):
                for scale in (1, 2):
                    suffix = "@2x" if scale == 2 else ""
                    shutil.copyfile(OUT / f"app-icon-{size * scale}.png",
                                    iconset / f"icon_{size}x{size}{suffix}.png")
            run("iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "HemDif.icns"))


if __name__ == "__main__":
    main()
