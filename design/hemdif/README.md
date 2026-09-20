# Hemdiff — Fold

The selected folded-ribbon concept, redrawn as editable vector geometry in Strøk.
The mark uses three named Bézier surfaces: `upper-tail`, `lower-tail`, and
`ribbon`. It contains no embedded raster image, fonts, or traced pixel contours.

## Sources

- `fold.strok`: primary teal mark, transparent background, 100 × 100 canvas.
- `fold-mono.strok`: a live union of the same geometry with `currentColor` fill.
- `app-icon.strok`: graphite rounded tile with brighter tails for dark contrast.
  The tile occupies 82% of its canvas to align optically with neighboring Dock
  icons; the entire mark and tile scale together.

The latter two import the shapes from `fold.strok`. Edit the master to change
all versions together. Gradients provide the fold depth; the monochrome mark
retains its silhouette without shading. The sources include intentional padding.

## Export

Requires `strok` on PATH. No Python packages are needed for regeneration.

```sh
python3 design/hemdif/export.py
```

This audits all sources and produces SVG plus PNG at 16, 20, 24, 32, 64, 128,
256, 512, and 1024 pixels. White monochrome PNGs are included at menu-bar sizes.
On macOS, `iconutil` also produces `exports/HemDif.icns` with 1× and 2× slots.
The monochrome SVG keeps `currentColor` for CSS theming.

Individual conversions:

```sh
strok -f design/hemdif/fold.strok export svg --out /tmp/hemdif.svg
strok -f design/hemdif/fold.strok export png --width 2048 --out /tmp/hemdif.png
strok -f design/hemdif/fold-mono.strok export png --width 20 --color '#FFFFFF' --out /tmp/hemdif-menu.png
strok watch design/hemdif/fold.strok
```

## Notes

SVG exports retain cubic paths and linear gradients, and the PNGs are transparent
outside their artwork. `size-proof.png` is a contact sheet for checking the mark
at small sizes, not a production asset.

After changing the mark, regenerate the exports and copy them into the app asset
catalog under `DiskSift/Resources/Assets.xcassets/`. Keep the existing filenames.
