# Poppler PDF Image Extractor (Docker Swarm Watch Folder)

This stack runs a single Swarm service that watches a shared folder and automatically extracts images from any PDF you drop into the **input** directory.

## Folder layout (under `/volume1/docker/pdf`)

Create these subfolders:

- `/volume1/docker/pdf/in` — drop PDFs here
- `/volume1/docker/pdf/out` — extracted images go here (one subfolder per PDF)
- `/volume1/docker/pdf/archive` — processed PDFs are moved here
- `/volume1/docker/pdf/failed` — PDFs that error or produce no outputs

## Modes

- `MODE=images` (default): uses `pdfimages -all` to extract embedded images (best quality).
- `MODE=pages`: uses `pdftoppm` to render each page to PNG (best for scanned/flattened PDFs).

## Deploy

1. Put these files in a folder on a manager node.

2. Build & push the image (or build on each node that might run it):

```bash
docker build -t polyhydra/poppler-watcher:1.0 .
# optionally push to your registry
# docker tag polyhydra/poppler-watcher:1.0 registry.local/polyhydra/poppler-watcher:1.0
# docker push registry.local/polyhydra/poppler-watcher:1.0
```

3. Deploy the stack:

```bash
docker stack deploy -c stack.yml pdf
```

## Important Swarm note

If `/volume1/docker/pdf` only exists on **one** Swarm node, you MUST pin the service to that node using `placement.constraints`
in `stack.yml` (uncomment and set the hostname).
