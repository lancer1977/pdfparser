\
#!/usr/bin/env bash
set -euo pipefail

INPUT_DIR="${INPUT_DIR:-/work/in}"
OUTPUT_DIR="${OUTPUT_DIR:-/work/out}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/work/archive}"
FAILED_DIR="${FAILED_DIR:-/work/failed}"
STABLE_SECONDS="${STABLE_SECONDS:-2}"
MODE="${MODE:-images}" # images | pages

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$ARCHIVE_DIR" "$FAILED_DIR"

log() { echo "[$(date -Iseconds)] $*"; }

# Wait until file hasn't changed size/mtime for STABLE_SECONDS.
wait_until_stable() {
  local f="$1"
  local last_sig=""
  while true; do
    # If file disappeared, bail.
    [[ -f "$f" ]] || return 1

    # size + mtime signature
    local sig
    sig="$(stat -c '%s:%Y' "$f" 2>/dev/null || true)"
    if [[ "$sig" == "$last_sig" && -n "$sig" ]]; then
      sleep "$STABLE_SECONDS"
      local sig2
      sig2="$(stat -c '%s:%Y' "$f" 2>/dev/null || true)"
      [[ "$sig2" == "$sig" ]] && return 0
    fi
    last_sig="$sig"
    sleep 0.5
  done
}

process_pdf() {
  local pdf="$1"
  local base_name
  base_name="$(basename "$pdf")"
  local stem="${base_name%.*}"

  log "Detected PDF: $base_name"

  if ! wait_until_stable "$pdf"; then
    log "File vanished before stable: $base_name"
    return 0
  fi

  local out_dir="$OUTPUT_DIR/$stem"
  mkdir -p "$out_dir"

  # Dedupe: if marker exists, skip
  if [[ -f "$out_dir/.done" ]]; then
    log "Already processed (marker exists), archiving: $base_name"
    mv -f "$pdf" "$ARCHIVE_DIR/$base_name" || true
    return 0
  fi

  # Extract
  if [[ "$MODE" == "pages" ]]; then
    log "Rendering pages via pdftoppm -> PNG into $out_dir"
    # -r sets DPI. 150 is a nice default; bump to 300 if you need higher.
    pdftoppm -r 150 -png "$pdf" "$out_dir/page" >/dev/null 2>&1
  else
    log "Extracting embedded images via pdfimages -all into $out_dir"
    pdfimages -all "$pdf" "$out_dir/img" >/dev/null 2>&1
  fi

  # Basic success check: any output files?
  if compgen -G "$out_dir/*.*" > /dev/null; then
    touch "$out_dir/.done"
    log "Success: wrote outputs to $out_dir"
    mv -f "$pdf" "$ARCHIVE_DIR/$base_name"
  else
    log "No outputs produced. Moving to failed."
    mv -f "$pdf" "$FAILED_DIR/$base_name"
    # Leave directory for inspection
    echo "No outputs created. Try MODE=pages for scanned PDFs." > "$out_dir/README.txt"
  fi
}

# On startup, process anything already in INPUT_DIR
shopt -s nullglob
for f in "$INPUT_DIR"/*.pdf "$INPUT_DIR"/*.PDF; do
  process_pdf "$f" || true
done

log "Watching $INPUT_DIR for new PDFs… (MODE=$MODE)"

# Watch for close_write (finished writing) and moved_to (atomic moves into folder)
inotifywait -m -e close_write -e moved_to --format '%w%f' "$INPUT_DIR" | while read -r file; do
  case "$file" in
    *.pdf|*.PDF) process_pdf "$file" || true ;;
    *) ;;
  esac
done
