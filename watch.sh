   #!/usr/bin/env bash
    set -euo pipefail

    INPUT_DIR="${INPUT_DIR:-/work/in}"
    OUTPUT_DIR="${OUTPUT_DIR:-/work/out}"
    ARCHIVE_DIR="${ARCHIVE_DIR:-/work/archive}"
    FAILED_DIR="${FAILED_DIR:-/work/failed}"

    STABLE_SECONDS="${STABLE_SECONDS:-2}"

    # MODE:
    #   pages  -> render each page to PNG (recommended when PDFs tile images)
    #   images -> extract embedded image objects (pdfimages) (best when you want raw assets)
    #   both   -> do both into subfolders
    MODE="${MODE:-both}"

    # Rendering
    RENDERER="${RENDERER:-pdftocairo}"   # pdftocairo | pdftoppm
    DPI="${DPI:-300}"

    # Image organization / filtering (for MODE=images or both)
    MIN_W="${MIN_W:-32}"
    MIN_H="${MIN_H:-32}"
    MIN_PIXELS="${MIN_PIXELS:-10000}"
    # If an image has <= this % non-white pixels, treat as blank/background and move to _blank
    BLANK_MAX_NONWHITE_PCT="${BLANK_MAX_NONWHITE_PCT:-0.5}"

    mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$ARCHIVE_DIR" "$FAILED_DIR"

    log() { echo "[$(date -Iseconds)] $*"; }

    sha256() { sha256sum "$1" | awk '{print $1}'; }

    # Wait until file hasn't changed size/mtime for STABLE_SECONDS.
    wait_until_stable() {
        local f="$1"
        local last_sig=""
        while true; do
            [[ -f "$f" ]] || return 1
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

    already_done() {
        local out_dir="$1"
        local pdf_sha="$2"

        local marker="$out_dir/.done.json"
        [[ -f "$marker" ]] || return 1

        local existing_sha existing_mode existing_dpi existing_renderer
        existing_sha="$(grep -E '"pdf_sha256"\s*:\s*"' "$marker" | sed -E 's/.*"pdf_sha256"\s*:\s*"([^"]+)".*/\1/' || true)"
        existing_mode="$(grep -E '"mode"\s*:\s*"' "$marker" | sed -E 's/.*"mode"\s*:\s*"([^"]+)".*/\1/' || true)"
        existing_dpi="$(grep -E '"dpi"\s*:\s*"' "$marker" | sed -E 's/.*"dpi"\s*:\s*"([^"]+)".*/\1/' || true)"
        existing_renderer="$(grep -E '"renderer"\s*:\s*"' "$marker" | sed -E 's/.*"renderer"\s*:\s*"([^"]+)".*/\1/' || true)"

        [[ "$existing_sha" == "$pdf_sha" ]] \
          && [[ "$existing_mode" == "$MODE" ]] \
          && [[ "$existing_dpi" == "$DPI" ]] \
          && [[ "$existing_renderer" == "$RENDERER" ]]
    }

    write_done_marker() {
        local out_dir="$1"
        local pdf="$2"
        local pdf_sha="$3"
        cat > "$out_dir/.done.json" <<EOF
    {
      "pdf": "$(basename "$pdf")",
      "pdf_sha256": "$pdf_sha",
      "mode": "$MODE",
      "renderer": "$RENDERER",
      "dpi": "$DPI",
      "processed_at": "$(date -Iseconds)"
    }
    EOF
    }

    render_pages() {
        local pdf="$1"
        local pages_dir="$2"
        mkdir -p "$pages_dir"

        if [[ "$RENDERER" == "pdftoppm" ]]; then
            pdftoppm -r "$DPI" -png "$pdf" "$pages_dir/page" >/dev/null 2>&1
        else
            pdftocairo -png -r "$DPI" "$pdf" "$pages_dir/page" >/dev/null 2>&1
        fi
    }

    # ---- Image filtering / organization helpers (requires ImageMagick: identify+convert) ----

    # Returns "percent_nonwhite" as a floating number (e.g., 0.23)
    percent_nonwhite() {
      local img="$1"
      convert "$img" \
        -background white -alpha remove -alpha off \
        -colorspace Gray \
        -threshold 99% \
        -format "%[fx:(1-mean)*100]" info:
    }

    is_blankish() {
      local img="$1"
      local p
      p="$(percent_nonwhite "$img" 2>/dev/null || echo "100")"
      awk -v val="$p" -v max="$BLANK_MAX_NONWHITE_PCT" 'BEGIN{exit !(val<=max)}'
    }

    organize_extracted_images() {
      local pdf="$1"
      local img_dir="$2"
      local list_file="$img_dir/_list.txt"

      mkdir -p "$img_dir/_blank" "$img_dir/_tiny" "$img_dir/_masks" "$img_dir/_unknown"

      pdfimages -list "$pdf" > "$list_file" 2>/dev/null || true

      # Parse: page num ... width height color ... bpc ...
      awk 'BEGIN{seen=0}
           /^page[[:space:]]+num/ {seen=1; next}
           seen && NF>=8 {print $1, $2, $4, $5, $6, $8}' "$list_file" | \
      while read -r page num w h color bpc; do
        local idx src
        idx="$(printf "%03d" "$num")"
        src="$(ls -1 "$img_dir"/img-"$idx".* 2>/dev/null | head -n 1 || true)"
        [[ -n "$src" ]] || continue

        # Masks: often gray + 1 bpc
        if [[ "${color,,}" == "gray" && "${bpc:-}" == "1" ]]; then
          mv -f "$src" "$img_dir/_masks/$(basename "$src")" 2>/dev/null || true
          continue
        fi

        # Tiny: by metadata width/height/pixels
        local pixels=$((w*h))
        if [[ "$w" -lt "$MIN_W" || "$h" -lt "$MIN_H" || "$pixels" -lt "$MIN_PIXELS" ]]; then
          mv -f "$src" "$img_dir/_tiny/$(basename "$src")" 2>/dev/null || true
          continue
        fi

        # Blank-ish: by pixel inspection (mostly white/empty)
        if is_blankish "$src"; then
          mv -f "$src" "$img_dir/_blank/$(basename "$src")" 2>/dev/null || true
          continue
        fi

        # Otherwise: group by page folder and rename with metadata
        local pdir="$img_dir/p$(printf "%03d" "$page")"
        mkdir -p "$pdir"

        local ext="${src##*.}"
        local base="p$(printf "%03d" "$page")_n${idx}_w${w}_h${h}_${color}${bpc}.${ext}"
        mv -f "$src" "$pdir/$base" 2>/dev/null || mv -f "$src" "$img_dir/_unknown/$(basename "$src")"
      done

      # Anything left unmapped -> _unknown
      shopt -s nullglob
      for f in "$img_dir"/img-*.png "$img_dir"/img-*.jpg "$img_dir"/img-*.tif "$img_dir"/img-*.ppm "$img_dir"/img-*.pbm; do
        mv -f "$f" "$img_dir/_unknown/$(basename "$f")" 2>/dev/null || true
      done
    }

    extract_images() {
        local pdf="$1"
        local img_dir="$2"
        mkdir -p "$img_dir"

        pdfimages -all "$pdf" "$img_dir/img" >/dev/null 2>&1 || true
        organize_extracted_images "$pdf" "$img_dir"
    }

    process_pdf() {
        local pdf="$1"
        local base_name stem
        base_name="$(basename "$pdf")"
        stem="${base_name%.*}"

        log "Detected PDF: $base_name"

        if ! wait_until_stable "$pdf"; then
            log "File vanished before stable: $base_name"
            return 0
        fi

        local out_dir="$OUTPUT_DIR/$stem"
        mkdir -p "$out_dir"

        local pdf_sha
        pdf_sha="$(sha256 "$pdf")"

        if already_done "$out_dir" "$pdf_sha"; then
            log "Already processed with same settings+hash; archiving: $base_name"
            mv -f "$pdf" "$ARCHIVE_DIR/$base_name" || true
            return 0
        fi

        log "Processing (MODE=$MODE, RENDERER=$RENDERER, DPI=$DPI)…"

        rm -rf "$out_dir/pages" "$out_dir/images" 2>/dev/null || true

        set +e
        if [[ "$MODE" == "pages" ]]; then
            render_pages "$pdf" "$out_dir/pages"
        elif [[ "$MODE" == "images" ]]; then
            extract_images "$pdf" "$out_dir/images"
        else
            render_pages "$pdf" "$out_dir/pages"
            extract_images "$pdf" "$out_dir/images"
        fi
        local rc=$?
        set -e

        if compgen -G "$out_dir/pages/*.png" > /dev/null || compgen -G "$out_dir/images/*/*.*" > /dev/null || compgen -G "$out_dir/images/*.*" > /dev/null; then
            write_done_marker "$out_dir" "$pdf" "$pdf_sha"
            log "Success: wrote outputs to $out_dir"
            mv -f "$pdf" "$ARCHIVE_DIR/$base_name"
        else
            log "No outputs produced (rc=$rc). Moving to failed."
            mv -f "$pdf" "$FAILED_DIR/$base_name"
            echo "No outputs created. Try MODE=pages or increase DPI." > "$out_dir/README.txt"
        fi
    }

    shopt -s nullglob
    for f in "$INPUT_DIR"/*.pdf "$INPUT_DIR"/*.PDF; do
        process_pdf "$f" || true
    done

    log "Watching $INPUT_DIR for new PDFs…"
    inotifywait -m -e close_write -e moved_to --format '%w%f' "$INPUT_DIR" | while read -r file; do
        case "$file" in
            *.pdf|*.PDF) process_pdf "$file" || true ;;
            *) ;;
        esac
    done
