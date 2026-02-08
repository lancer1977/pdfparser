# Poppler PDF Watch Folder – organized segments + blank filtering

Many PDFs *tile* artwork into multiple image objects (quarters/strips) for rendering/compression.
`pdfimages` extracts those objects exactly as stored, so you may see chopped segments.

This watcher supports:
- **pages**: render full pages to PNG (recommended for “what it looks like”)
- **images**: extract embedded image objects, then **organize + filter**
- **both**: do both

## Folder layout (under `/volume1/docker/pdf` mounted to `/work`)
- `/work/in` — drop PDFs here
- `/work/out` — outputs go here (one subfolder per PDF)
- `/work/archive` — processed PDFs are moved here
- `/work/failed` — PDFs that error or produce no outputs

## Output layout per PDF
`/work/out/<pdf-stem>/`
- `pages/` — full rendered pages (`MODE=pages` or `MODE=both`)
- `images/` — organized extracted assets (`MODE=images` or `MODE=both`)
  - `p###/` — “good” assets grouped by page, renamed with metadata
  - `_blank/` — mostly-white/empty images (backgrounds)
  - `_tiny/` — small strips/icons/noise (below thresholds)
  - `_masks/` — likely 1-bit masks/stencils
  - `_unknown/` — anything that couldn’t be mapped cleanly
  - `_list.txt` — raw `pdfimages -list` output for debugging/tweaks
- `.done.json` — marker containing pdf hash + settings

## Filtering knobs (environment variables)
- `MIN_W`, `MIN_H`, `MIN_PIXELS` — bucket tiny stuff to `_tiny`
- `BLANK_MAX_NONWHITE_PCT` — bucket blank-ish to `_blank` (default 0.5%)

## Why this helps
- You keep the raw segments, but you’ll find them under `images/p001`, `images/p002`, etc.
- Junk (masks/tiny/blank) is separated so your main asset folders are usable.

## Deploy
```bash
docker build -t polyhydra/poppler-watcher:1.2 .
docker stack deploy -c stack.yml pdf
```
