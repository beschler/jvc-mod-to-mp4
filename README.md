# jvc-mod-to-mp4

A bash script for converting `.mod` video files from the **JVC GZ-MG465BAA** hard disk camcorder to `.mp4`, with full metadata preservation, correct PAL colour space tagging, deinterlacing, and optional square-pixel resampling.

Tested on macOS Sequoia with an Apple M2 Pro. Should work on any macOS version with Homebrew available.

---

## Supported Hardware

| Camcorder | Region | Frame Rate |
|---|---|---|
| JVC GZ-MG465BAA | Australia / PAL | 25 fps |

> **Note:** This script is written specifically for the **PAL** variant of this camcorder (sold in Australia and Europe). The North American model records at 30 fps (NTSC) and is not supported without modification.

---

## What the Script Does

- Finds `.mod` files inside `input/PRG###/` subfolders, mirroring the camcorder's native folder structure. Falls back to files placed directly in `input/` if no `PRG` subfolders are present (treated as `PRG001`).
- Reads the `.moi` sidecar file paired with each `.mod` to extract the original recording date and time.
- Deinterlaces interlaced PAL video (25i) to progressive (25p) using the `bwdif` filter, matching how VLC plays back the original files.
- Encodes video as **H.265 (HEVC)** by default, or **H.264** in archive mode.
- In default mode, scales the video to its correct square-pixel display resolution using the source SAR (Sample Aspect Ratio), computed dynamically at encode time:
  - PAL 16:9 (SAR 64:45): 720×576 → **1024×576**
  - PAL 4:3 (SAR 16:15): 720×576 → **768×576**
  - Economy mode and other resolutions: computed automatically
- Scaling uses the **Lanczos** algorithm - the highest-quality resampling filter available in ffmpeg.
- Encodes audio as **AAC 192k** (required, as MP4 containers do not natively support raw MPEG-2 audio).
- Embeds correct **BT.601 PAL colour space metadata** (`bt470bg` primaries, `gamma28` transfer curve, `bt470bg` matrix, limited/TV range) so that standards-compliant players and editors display colours accurately.
- Embeds the recording date as **`creation_time`** metadata inside the MP4.
- Sets the output file's **filesystem "Date Modified"** timestamp to match the recording date (via `touch`).
- Sets the output file's **filesystem "Date Created"** timestamp to match the recording date (via `SetFile` from Xcode Command Line Tools, if installed).
- Names output files using a unique, human-readable convention based on PRG folder, clip number, and recording date - ensuring no filename collisions even across multiple `PRG` folders recorded on the same day.
- Prints per-file progress including input file size, output file size, percentage of original size, and elapsed time.
- Handles Ctrl+C cleanly, removing any partial output file that was in progress.

---

## Output File Naming

```
MOV{PRG}--{INT}--{DATE}.mp4
```

| Part | Description | Example |
|---|---|---|
| `{PRG}` | 3-digit PRG folder number | `001`, `002` |
| `{INT}` | Decimal equivalent of the hex filename | `MOV00A` → `10` |
| `{DATE}` | Recording date from `.moi` sidecar | `2025-09-08` |

If the recording date is unavailable (no `.moi` file), the date portion is omitted:

```
MOV001--1.mp4
```

### Examples

```
input/PRG001/MOV001.MOD  →  output/MOV001--1--2025-09-08.mp4
input/PRG001/MOV00A.MOD  →  output/MOV001--10--2025-09-08.mp4
input/PRG002/MOV001.MOD  →  output/MOV002--1--2025-09-09.mp4
```

---

## Modes

### Default Mode - H.265, Square Pixels (recommended)

```bash
bash jvc-mod-to-mp4.sh
```

Scales the video to its correct square-pixel display resolution and encodes as **H.265 (HEVC)**. Recommended for editing and delivery. Rotation of clips in DaVinci Resolve, QuickTime, or VLC works correctly with no aspect ratio distortion.

**Encoder selection (automatic):**

| Machine | Encoder Used | Speed |
|---|---|---|
| Apple Silicon (M1/M2/M3/M4) | `hevc_videotoolbox` (hardware) at `-q:v 60` | Near-realtime |
| Intel Mac / other | `libx265` (software) at `-crf 22` | Slower |

The script automatically detects whether Apple's hardware H.265 encoder is available by running a short test encode at startup. If hardware encoding is available it is used; otherwise the software encoder is selected transparently with no action required.

### Archive Mode - H.264, Non-Square Pixels

```bash
bash jvc-mod-to-mp4.sh -a
```

No scaling is applied. The SAR (non-square pixel) flag from the source MPEG-2 stream is carried through automatically. Output is stored at the original storage dimensions (e.g. 720×576) with a non-square PAR tag - functionally identical to the original `.mod` file. Encodes as **H.264** (`libx264`, CRF 18, `preset slow`) for maximum compatibility and visually indistinguishable (however not technically lossless) quality.

> **Warning:** Rotating clips 90° from archive-mode files in any editing application will produce distorted aspect ratios, due to the non-square pixel geometry interacting with the rotation transform. Use default mode if you plan to rotate clips.

---

## Prerequisites

### Required

| Tool | Purpose | Install |
|---|---|---|
| `ffmpeg` (with `ffprobe`) | Video conversion | `brew install ffmpeg` |
| `xxd` | Parse binary `.moi` sidecar files | Pre-installed on macOS |
| `bash` | Run the script | Pre-installed on macOS |

### Optional (but recommended)

| Tool | Purpose | Install |
|---|---|---|
| `SetFile` | Set "Date Created" in Finder | `xcode-select --install` |

Without `SetFile`, only the "Date Modified" filesystem timestamp will be set. The recording date is still embedded correctly inside the MP4 metadata regardless.

To verify `SetFile` is available after installing:

```bash
which SetFile
# Expected output: /usr/bin/SetFile
```

---

## Installation

**1. Install Homebrew** (if not already installed):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**2. Install ffmpeg:**

```bash
brew install ffmpeg
```

**3. Install Xcode Command Line Tools** (for `SetFile`, optional):

```bash
xcode-select --install
```

**4. Clone this repository:**

```bash
git clone https://github.com/YOUR_USERNAME/jvc-mod-to-mp4.git
cd jvc-mod-to-mp4
```

---

## Folder Structure

Place the script in a dedicated working directory. The script will automatically create `input/` and `output/` folders adjacent to itself on first run.

You must add `.MOD` and `.MOI` files - preferably in `{PRG}` folders - into the `input/` directory, and the script will output `.mp4` files to the `output/` directory, like this:

```
jvc-mod-to-mp4/
├── jvc-mod-to-mp4.sh
├── input/
│   ├── PRG001/
│   │   ├── MOV001.MOD
│   │   ├── MOV001.MOI
│   │   ├── MOV002.MOD
│   │   └── MOV002.MOI
│   └── PRG002/
│       ├── MOV001.MOD
│       └── MOV001.MOI
└── output/
    ├── MOV001--1--2025-09-08.mp4
    ├── MOV001--2--2025-09-08.mp4
    └── MOV002--1--2025-09-09.mp4
```

**Fallback (no PRG subfolders):** if `.mod` files are placed directly inside `input/` (no `{PRG}` subfolders), they are treated as if they came from `PRG001`:

```
jvc-mod-to-mp4/
├── jvc-mod-to-mp4.sh
├── input/
│   ├── MOV001.MOD
│   ├── MOV001.MOI
│   ├── MOV002.MOD
│   └── MOV002.MOI
└── output/
    ├── MOV001--1--2025-09-08.mp4
    └── MOV001--2--2025-09-08.mp4
```

The `.moi` sidecar files do not need to be removed from the input folder - the script ignores everything that isn't a `.mod` file. `.pgi` and other camcorder files can be left in place safely.

---

## Usage

Navigate to the folder containing the script:

```bash
cd path/to/jvc-mod-to-mp4
```

**Default mode** (H.265, square pixels, recommended):

```bash
bash jvc-mod-to-mp4.sh
```

**Archive mode** (H.264, non-square pixels, no resampling):

```bash
bash jvc-mod-to-mp4.sh -a
```

**Cancel at any time** with `Ctrl+C`. Any partially-written output file will be removed automatically.

---

## Example Output

```
════════════════════════════════════════════
  Found     : 99 file(s)
  Structure : PRG subfolders detected
  Mode      : Default - H.265 hardware (hevc_videotoolbox), square pixels
  Dates     : Date Modified + Date Created will be set
  Press Ctrl+C to cancel at any time
════════════════════════════════════════════

  [01/99]  → Starting : PRG001/MOV001.MOD → MOV001--1--2025-09-08.mp4 (48.3 MB)
  [01/99]  ✓ Done     : MOV001--1--2025-09-08.mp4 (17.1 MB - 35% of original, 0m 14s)

  [02/99]  → Starting : PRG001/MOV002.MOD → MOV001--2--2025-09-08.mp4 (124.6 MB)
  [02/99]  ✓ Done     : MOV001--2--2025-09-08.mp4 (41.2 MB - 33% of original, 0m 32s)

════════════════════════════════════════════
  Total     : 99
  Converted : 99
  Failed    : 0
  Time      : 2m 12s
  Output in : /path/to/jvc-mod-to-mp4/output
════════════════════════════════════════════
```

---

## Notes on Colour Accuracy

The script embeds BT.601 PAL colour space metadata into every output file. Standards-compliant players (VLC, IINA, DaVinci Resolve) will display colours correctly and identically to the original `.mod` files.

**QuickTime Player** has a long-standing issue with BT.601 SD footage that causes washed-out colours regardless of the metadata embedded in the file. This is a QuickTime limitation and not a problem with the encoded files. Use VLC to verify conversion quality.

---

## Encoding Details

| Property | Default Mode | Archive Mode |
|---|---|---|
| Video codec | H.265 (HEVC) | H.264 |
| Encoder | `hevc_videotoolbox` (hw) or `libx265` (sw) | `libx264` |
| Quality | `-q:v 60` (hw) / `-crf 22` (sw) | `-crf 18` |
| Preset | - | `slow` |
| Pixel format | `yuv420p` | `yuv420p` |
| Scaling | `iw*sar:ih`, Lanczos | None (SAR preserved) |
| Deinterlace | `bwdif=send_frame` (25fps) | `bwdif=send_frame` (25fps) |
| Audio codec | AAC 192k | AAC 192k |
| Colour space | BT.601 PAL (`bt470bg`) | BT.601 PAL (`bt470bg`) |
| Colour range | Limited / TV (16–235) | Limited / TV (16–235) |
| Container | MP4 with `faststart` | MP4 with `faststart` |
