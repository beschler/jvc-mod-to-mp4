#!/usr/bin/env bash
# jvc-mod-to-mp4.sh — Convert JVC GZ-MG465BAA camcorder .mod files to .mp4
#
# USAGE:
#   bash jvc-mod-to-mp4.sh          # Default: square-pixel H.265 mode (recommended)
#   bash jvc-mod-to-mp4.sh -a       # Archive mode: H.264, non-square PAL pixels
#
# Press Ctrl+C at any time to cancel cleanly.
#
# ─── MODES ────────────────────────────────────────────────────────────────────
#
#   DEFAULT (no flag) — Square-pixel H.265 mode:
#     Scales the video to its correct square-pixel display resolution using the
#     ffmpeg filter expression "iw*sar:ih" — this reads the SAR (Sample Aspect
#     Ratio) and source dimensions directly from the stream at encode time, so
#     dimensions are always computed correctly regardless of resolution:
#       PAL 16:9 (SAR 64:45): 720×576 → 1024×576
#       PAL  4:3 (SAR 16:15): 720×576 →  768×576
#       Economy  (SAR varies): computed dynamically from source
#     Scaling uses Lanczos — the highest-quality resampling filter in ffmpeg.
#     Video is encoded as H.265 (HEVC) for smaller file sizes at equal quality.
#     Hardware encoding via hevc_videotoolbox is used automatically on Apple
#     Silicon Macs (M1/M2/M3/M4), falling back to software libx265 otherwise.
#     Rotation in DaVinci Resolve, QuickTime, or VLC works correctly with no
#     aspect ratio distortion. Recommended for editing and delivery.
#
#   ARCHIVE (-a flag) — Non-square pixel H.264 mode:
#     No scaling. The SAR flag is carried through from the source MPEG-2 stream
#     automatically. Video is encoded as H.264 for maximum compatibility.
#     Output is stored at the original storage dimensions (e.g. 720×576) with
#     a non-square PAR tag — identical in principle to the original .mod file.
#     Players that respect the PAR tag (VLC, DaVinci Resolve, etc.) display it
#     at the correct proportions. Rotating 90° in any application will produce
#     distorted dimensions. Use for archival where storage matters and footage
#     will not be rotated.
#
# ─── ENCODER SELECTION (default mode) ────────────────────────────────────────
#
#   Hardware (hevc_videotoolbox, Apple Silicon only):
#     Uses the M-series media engine. Near-realtime encode speed. Quality set
#     via -q:v 60 (scale 1–100, higher = better). Produces slightly larger
#     files than software at equivalent visual quality, but is dramatically
#     faster. Requires ffmpeg 4.4+ and Apple Silicon.
#
#   Software fallback (libx265):
#     Used automatically on Intel Macs or when videotoolbox is unavailable.
#     Quality set via -crf 22 (visually lossless for H.265). Slower but
#     produces smaller files at equivalent quality.
#
# ─── FOLDER STRUCTURE ─────────────────────────────────────────────────────────
#
#   Place PRG subfolders inside input/, mirroring the camcorder's structure:
#
#     input/PRG001/MOV001.MOD   →   output/MOV001--1--2025-09-08.mp4
#     input/PRG001/MOV001.MOI
#     input/PRG002/MOV001.MOD   →   output/MOV002--1--2025-09-08.mp4
#     input/PRG002/MOV001.MOI
#
#   Fallback: if .mod files are placed directly in input/ (no PRG subfolder),
#   they are treated as if they came from PRG001.
#
# ─── OUTPUT FILE NAMING ───────────────────────────────────────────────────────
#
#   MOV{PRG}--{INT}--{DATE}.mp4
#     {PRG}  = 3-digit PRG folder number (e.g. 001, 002)
#     {INT}  = decimal equivalent of the hex filename (e.g. MOV00A → 10)
#     {DATE} = recording date from .moi sidecar (YYYY-MM-DD)
#   If date is unavailable: MOV{PRG}--{INT}.mp4
#
# ─── ENCODING SUMMARY ─────────────────────────────────────────────────────────
#
#   Both modes:
#     Audio       : AAC 192k (MP4 can't carry raw MPEG-2 audio)
#     Deinterlace : bwdif=send_frame (25fps, matches VLC on-the-fly playback)
#     Pixel format: yuv420p (maximum compatibility)
#
#   Default mode:
#     Video codec : H.265 (hardware hevc_videotoolbox or software libx265)
#     Scaling     : iw*sar:ih with Lanczos (dynamic square-pixel correction)
#
#   Archive mode (-a):
#     Video codec : H.264 (libx264, CRF 18, preset slow)
#     Scaling     : none (SAR carried through from source)
#
# ─── METADATA ─────────────────────────────────────────────────────────────────
#
#   Recording date/time embedded as creation_time. Both filesystem "Date Modified"
#   (touch) and "Date Created" (SetFile, Xcode CLI tools) are set to match.
#   To install SetFile: xcode-select --install
#   To check:          xcode-select -p  /  which SetFile

set -euo pipefail

# ─── Parse arguments ──────────────────────────────────────────────────────────

ARCHIVE_MODE=0

while getopts ":a" opt; do
  case $opt in
    a) ARCHIVE_MODE=1 ;;
    *) echo "Usage: bash jvc-mod-to-mp4.sh [-a]"
       echo "  (no flag)  Default: square-pixel H.265, hardware-accelerated on Apple Silicon"
       echo "  -a         Archive: non-square PAL pixels, H.264, no scaling"
       exit 1 ;;
  esac
done

# ─── Paths ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="$SCRIPT_DIR/input"
OUTPUT_DIR="$SCRIPT_DIR/output"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

# ─── Check for dependencies ───────────────────────────────────────────────────

for cmd in ffmpeg ffprobe xxd; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' not found. Install with: brew install ffmpeg"
    exit 1
  fi
done

HAS_SETFILE=0
command -v SetFile >/dev/null 2>&1 && HAS_SETFILE=1

if [ "$HAS_SETFILE" = "0" ]; then
  echo "Note: 'SetFile' not found — Finder 'Date Created' will not be set."
  echo "      To enable: xcode-select --install"
  echo ""
fi

# ─── Detect hardware H.265 encoder (default mode only) ───────────────────────
# hevc_videotoolbox is Apple's hardware H.265 encoder, available on Apple
# Silicon Macs (M1/M2/M3/M4) with ffmpeg 4.4+. We test it by running a
# short dummy encode to /dev/null — if it succeeds, hardware is available.
# Falls back to software libx265 automatically.

HAS_HW_HEVC=0
if [ "$ARCHIVE_MODE" = "0" ]; then
  if ffmpeg -f lavfi -i nullsrc=s=64x64:d=0.1 \
      -c:v hevc_videotoolbox -q:v 60 -tag:v hvc1 \
      -f mp4 /dev/null \
      -y -loglevel quiet 2>/dev/null; then
    HAS_HW_HEVC=1
  fi
fi

# ─── Ctrl+C handler ───────────────────────────────────────────────────────────

CURRENT_OUT=""

cleanup() {
  echo ""
  echo "  ✖ Cancelled."
  if [ -n "$CURRENT_OUT" ] && [ -f "$CURRENT_OUT" ]; then
    rm -f "$CURRENT_OUT"
    echo "  Removed partial file: $(basename "$CURRENT_OUT")"
  fi
  exit 1
}
trap cleanup INT TERM

# ─── Helper: hex filename suffix → decimal ────────────────────────────────────

hex_suffix_to_decimal() {
  local upper
  upper=$(echo "$1" | tr '[:lower:]' '[:upper:]')
  printf "%d" "0x${upper#MOV}"
}

# ─── Helper: extract PRG number from a folder path ────────────────────────────
# Returns the 3-digit number from a PRG### folder name, or "001" as fallback.

extract_prg() {
  local folder="$1"
  local upper
  upper=$(basename "$folder" | tr '[:lower:]' '[:upper:]')
  if echo "$upper" | grep -qE '^PRG[0-9]{3}$'; then
    echo "${upper#PRG}"
  else
    echo "001"
  fi
}

# ─── Helper: parse recording datetime from .moi binary sidecar ───────────────
# Offsets: 0x06-07 year, 0x08 month, 0x09 day, 0x0A hour, 0x0B min, 0x0C-0D ms
# Returns three lines:
#   Line 1 — ISO for ffmpeg:    "2009-09-06 14:23:07Z"
#   Line 2 — for SetFile:       "09/06/2009 14:23:07"
#   Line 3 — date for filename: "2009-09-06"

parse_moi_datetime() {
  local moi="$1"
  [ -f "$moi" ] || { printf "\n\n\n"; return; }

  local yh moh dh hh minh msh
  yh=$(xxd   -p -s 6  -l 2 "$moi" | tr -d '[:space:]')
  moh=$(xxd  -p -s 8  -l 1 "$moi" | tr -d '[:space:]')
  dh=$(xxd   -p -s 9  -l 1 "$moi" | tr -d '[:space:]')
  hh=$(xxd   -p -s 10 -l 1 "$moi" | tr -d '[:space:]')
  minh=$(xxd -p -s 11 -l 1 "$moi" | tr -d '[:space:]')
  msh=$(xxd  -p -s 12 -l 2 "$moi" | tr -d '[:space:]')

  local y mo d h mi ms s
  y=$(printf "%d"  "0x$yh")
  mo=$(printf "%d" "0x$moh")
  d=$(printf "%d"  "0x$dh")
  h=$(printf "%d"  "0x$hh")
  mi=$(printf "%d" "0x$minh")
  ms=$(printf "%d" "0x$msh")
  s=$((ms / 1000))

  printf "%04d-%02d-%02d %02d:%02d:%02dZ\n%02d/%02d/%04d %02d:%02d:%02d\n%04d-%02d-%02d\n" \
    "$y" "$mo" "$d" "$h" "$mi" "$s" \
    "$mo" "$d" "$y" "$h" "$mi" "$s" \
    "$y" "$mo" "$d"
}

# ─── Helper: format seconds as "Xh Xm Xs" ────────────────────────────────────

format_duration() {
  local secs="$1"
  local h=$(( secs / 3600 ))
  local m=$(( (secs % 3600) / 60 ))
  local s=$(( secs % 60 ))
  if [ "$h" -gt 0 ]; then
    printf "%dh %dm %ds" "$h" "$m" "$s"
  elif [ "$m" -gt 0 ]; then
    printf "%dm %ds" "$m" "$s"
  else
    printf "%ds" "$s"
  fi
}

# ─── Helper: format bytes as human-readable size ─────────────────────────────

format_bytes() {
  local bytes="$1"
  if [ "$bytes" -ge 1073741824 ]; then
    printf "%.1f GB" "$(echo "$bytes" | awk '{printf "%.1f", $1/1073741824}')"
  elif [ "$bytes" -ge 1048576 ]; then
    printf "%.1f MB" "$(echo "$bytes" | awk '{printf "%.1f", $1/1048576}')"
  elif [ "$bytes" -ge 1024 ]; then
    printf "%.1f KB" "$(echo "$bytes" | awk '{printf "%.1f", $1/1024}')"
  else
    printf "%d B" "$bytes"
  fi
}
# Search up to 2 levels deep:
#   Level 1: input/MOV001.MOD         (fallback — no PRG subfolder)
#   Level 2: input/PRG001/MOV001.MOD  (expected structure)

mod_files=()
while IFS= read -r -d '' f; do
  mod_files+=("$f")
done < <(find "$INPUT_DIR" -maxdepth 2 -type f -iname '*.mod' -print0)

total=${#mod_files[@]}

if [ "$total" -eq 0 ]; then
  echo "No .mod files found in: $INPUT_DIR"
  echo "Expected structure: input/PRG001/MOV001.MOD"
  exit 0
fi

# Detect whether PRG subfolders are present, for the summary message
has_prg_folders=0
for f in "${mod_files[@]}"; do
  parent=$(basename "$(dirname "$f")" | tr '[:lower:]' '[:upper:]')
  if echo "$parent" | grep -qE '^PRG[0-9]{3}$'; then
    has_prg_folders=1
    break
  fi
done

# ─── Summary header ───────────────────────────────────────────────────────────

echo "════════════════════════════════════════════"
echo "  Found     : $total file(s)"
if [ "$has_prg_folders" = "1" ]; then
  echo "  Structure : PRG subfolders detected"
else
  echo "  Structure : No PRG subfolders — using PRG001 as fallback"
fi
if [ "$ARCHIVE_MODE" = "1" ]; then
  echo "  Mode      : Archive (-a) — H.264, non-square pixels, no scaling"
elif [ "$HAS_HW_HEVC" = "1" ]; then
  echo "  Mode      : Default — H.265 hardware (hevc_videotoolbox), square pixels"
else
  echo "  Mode      : Default — H.265 software (libx265), square pixels"
fi
if [ "$HAS_SETFILE" = "1" ]; then
  echo "  Dates     : Date Modified + Date Created will be set"
else
  echo "  Dates     : Date Modified only (run xcode-select --install for Date Created)"
fi
echo "  Press Ctrl+C to cancel at any time"
echo "════════════════════════════════════════════"
echo ""

# ─── Sequential conversion loop ───────────────────────────────────────────────

converted=0
failed=0
index=0
total_start=$SECONDS

for file in "${mod_files[@]}"; do
  index=$((index + 1))

  local_width=${#total}
  padded_index=$(printf "%0${local_width}d" "$index")
  label="[${padded_index}/${total}]"
  file_start=$SECONDS

  base=$(basename "$file")
  name="${base%.*}"
  name_upper=$(echo "$name" | tr '[:lower:]' '[:upper:]')
  dir=$(dirname "$file")

  # PRG number from parent folder
  prg=$(extract_prg "$dir")

  # Decimal clip number from hex filename
  if echo "$name_upper" | grep -qE '^MOV[0-9A-F]{3}$'; then
    clip_int=$(hex_suffix_to_decimal "$name_upper")
  else
    clip_int="$name"
    echo "  $label    Warning  : '$base' doesn't match MOV### — using original name as clip ID."
  fi

  # Find paired .moi (case-insensitive)
  moi_file=""
  moi_found=$(find "$dir" -maxdepth 1 -type f -iname "${name_upper}.MOI" -print -quit 2>/dev/null)
  [ -n "$moi_found" ] && moi_file="$moi_found"

  # Parse datetime from .moi
  creation_iso=""
  creation_setfile=""
  creation_date=""
  if [ -n "$moi_file" ]; then
    dt_lines=$(parse_moi_datetime "$moi_file")
    creation_iso=$(echo "$dt_lines"     | sed -n '1p')
    creation_setfile=$(echo "$dt_lines" | sed -n '2p')
    creation_date=$(echo "$dt_lines"    | sed -n '3p')
  fi

  # Build output filename
  if [ -n "$creation_date" ]; then
    out_name="MOV${prg}--${clip_int}--${creation_date}"
  else
    out_name="MOV${prg}--${clip_int}"
  fi

  out="$OUTPUT_DIR/${out_name}.mp4"

  # Collision guard (should be very rare with PRG+INT+DATE naming)
  if [ -e "$out" ]; then
    c=2
    while [ -e "$OUTPUT_DIR/${out_name}--${c}.mp4" ]; do c=$((c+1)); done
    out="$OUTPUT_DIR/${out_name}--${c}.mp4"
  fi

  # ── Build video filter and encoder args ───────────────────────────────────────
  #
  # Default mode — square-pixel H.265:
  #   Filter: bwdif=mode=send_frame deinterlaces to 25fps progressive, then
  #   scale=iw*sar:ih applies the source SAR to compute the correct display
  #   width dynamically (e.g. 1024 for 16:9, 768 for 4:3), reading both the
  #   SAR and dimensions directly from the stream — no hard-coded values.
  #   The :flags=lanczos flag selects the Lanczos resampling algorithm.
  #   ow and oh in the mode note are resolved by ffprobe for display only.
  #
  #   Encoder: hevc_videotoolbox (hardware, Apple Silicon) at -q:v 60, or
  #   libx265 (software fallback) at -crf 22. Both tagged as hvc1 for full
  #   QuickTime / macOS / DaVinci Resolve compatibility.
  #
  # Archive mode — non-square H.264:
  #   Filter: bwdif=mode=send_frame only. No scaling; SAR carried through.
  #   Encoder: libx264, CRF 18, preset slow.

  if [ "$ARCHIVE_MODE" = "1" ]; then
    vf_filter="bwdif=mode=send_frame"
    video_args=(-c:v libx264 -crf 18 -preset slow)
  else
    vf_filter="bwdif=mode=send_frame,scale=trunc(iw*sar/2)*2:trunc(ih/2)*2:flags=lanczos"
    if [ "$HAS_HW_HEVC" = "1" ]; then
      video_args=(-c:v hevc_videotoolbox -q:v 60 -tag:v hvc1)
    else
      video_args=(-c:v libx265 -crf 22 -preset slow -tag:v hvc1)
    fi
  fi

  # Get input file size for the Starting line
  input_bytes=$(stat -f%z "$file" 2>/dev/null || echo "0")
  input_size=$(format_bytes "$input_bytes")

  # Build the input display path: "PRG002/MOV061.MOD" if in a PRG subfolder,
  # or just "MOV061.MOD" if files are directly in the input folder.
  parent_dir=$(basename "$dir" | tr '[:lower:]' '[:upper:]')
  if echo "$parent_dir" | grep -qE '^PRG[0-9]{3}$'; then
    input_display="${parent_dir}/${base}"
  else
    input_display="$base"
  fi

  echo "  $label  → Starting : $input_display → $(basename "$out") ($input_size)"

  [ -z "$moi_file" ] && \
    echo "  $label    Warning  : no .moi file found — date metadata will not be set"

  # Build optional ffmpeg metadata args
  meta_args=()
  [ -n "$creation_iso" ] && meta_args=(-metadata "creation_time=${creation_iso}")

  # Track current output file so cleanup() can remove it if cancelled mid-encode
  CURRENT_OUT="$out"

  # ── ffmpeg ────────────────────────────────────────────────────────────────────
  # Colour space flags (-color_primaries, -color_trc, -colorspace):
  #   Your .mod files are MPEG-2 encoded in BT.601 PAL colour space (bt470bg).
  #   Without explicitly carrying these tags through, ffmpeg leaves the output
  #   untagged or defaults to BT.709, causing players and editors to interpret
  #   the colours incorrectly — producing the washed-out, desaturated appearance.
  #   These flags label the colour space correctly without changing any pixel values.
  #
  # -color_range tv:
  #   Explicitly declares limited/broadcast range (16-235 luma), which is correct
  #   for PAL SD video and prevents hevc_videotoolbox from logging a warning about
  #   an unset color range.

  if ffmpeg \
      -nostdin \
      -hide_banner \
      -loglevel error \
      -i "$file" \
      -vf "$vf_filter" \
      "${video_args[@]}" \
      -pix_fmt yuv420p \
      -color_primaries bt470bg \
      -color_trc gamma28 \
      -colorspace bt470bg \
      -color_range tv \
      -c:a aac \
      -b:a 192k \
      "${meta_args[@]+"${meta_args[@]}"}" \
      -movflags +faststart \
      "$out"; then

    CURRENT_OUT=""

    # Set filesystem timestamps from .moi recording date
    if [ -n "$creation_iso" ]; then
      ty="${creation_iso:0:4}"; tm="${creation_iso:5:2}"; td="${creation_iso:8:2}"
      th="${creation_iso:11:2}"; tmi="${creation_iso:14:2}"; ts="${creation_iso:17:2}"
      TZ=UTC touch -t "${ty}${tm}${td}${th}${tmi}.${ts}" "$out"

      if [ "$HAS_SETFILE" = "1" ] && [ -n "$creation_setfile" ]; then
        SetFile -d "$creation_setfile" "$out"
      fi
    fi

    converted=$((converted + 1))
    output_bytes=$(stat -f%z "$out" 2>/dev/null || echo "0")
    output_size=$(format_bytes "$output_bytes")
    if [ "$input_bytes" -gt 0 ]; then
      pct=$(echo "$output_bytes $input_bytes" | awk '{printf "%d", ($1/$2)*100}')
      size_note="${output_size} — ${pct}% of original"
    else
      size_note="$output_size"
    fi
    echo "  $label  ✓ Done     : $(basename "$out") ($size_note, $(format_duration $((SECONDS - file_start))))"

  else
    CURRENT_OUT=""
    rm -f "$out" 2>/dev/null || true
    failed=$((failed + 1))
    echo "  $label  ✗ Failed   : $base ($(format_duration $((SECONDS - file_start))))"
  fi

done

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════"
echo "  Total     : $total"
echo "  Converted : $converted"
echo "  Failed    : $failed"
echo "  Time      : $(format_duration $((SECONDS - total_start)))"
echo "  Output in : $OUTPUT_DIR"
echo "════════════════════════════════════════════"
