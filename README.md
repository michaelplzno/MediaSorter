<!-- @format -->

# Media USB Project

## Executive summary

Goal: build a **simple “plug into TV and watch” USB flash drive** for your parents that contains a curated set of movies and TV shows from your archived Blu-rays/DVDs, without relying on streaming subscriptions.

Your current media library on \*\*D:\*\* is a mix of:

- Full movies (single large files)
- TV episodes (individual files and full seasons)
- **Season bundles stored as `.tar` archives**
- Personal/game capture clips and project videos mixed in

You wrote a PowerShell scanner that:

1. Recursively enumerates video files and archives on `D:\`
2. Uses **ffprobe** to extract metadata (duration, width, height)
3. Applies filename/path/duration heuristics to auto-classify items (Movie, TV_Episode, Personal, etc.)
4. Exports a CSV “inventory” that you can use to plan what goes on the USB and what gets backed up to Google Drive

Early results were incorrect because `ffprobe` output was being broken by `--%` combined with `2>&1`, but that’s now fixed and durations/resolutions are populating for most files.

Remaining improvements are mostly **classification tuning** and **handling tar season/movie bundles cleanly**.

---

# Current blockers / known issues

### Classification edge cases

Some items still hit `Unknown` even though they’re clearly Personal/TV/Short due to edge-case naming such as:

- Timestamp captures (example: `2023-06-10 16-21-38.mp4`)
- Anime style naming (`Ep06` instead of `S01E06`)
- Cartoons or short films (<20 minutes)

These need improved detection rules.

---

### ffprobe failures

Some rows show:

SizeGB = 0
Duration = 0
Width = 0
Height = 0

This likely indicates one of the following:

- Zero-byte file
- Corrupted file
- Permission issue
- ffprobe parsing failure
- Bad path or symlink

These files should be logged to `logs/ffprobe_failures.log` and reviewed manually.

---

### Archive classification

`.tar` archives currently fall into two categories:

- TV season bundles
- Movie archives

The scanner currently detects seasons but not movie bundles reliably.

We should classify archives as:

TV_SeasonBundle
MovieBundle
Archive_Unknown

---

# Next steps (project roadmap)

## 1. Move scripts into a VS Code project

Suggested structure:

media-usb-project/
│
├─ src/
│ ├─ ScanMedia.ps1
│ ├─ Classify.ps1
│ └─ BuildUsb.ps1
│
├─ data/
│ ├─ media_inventory.csv
│ └─ usb_plan.csv
│
├─ logs/
│ └─ ffprobe_failures.log
│
├─ README.md
└─ .vscode/

## 2. Harden the scanner

Improve the scanning stage by:

- Logging all ffprobe failures
- Detecting zero-byte files
- Adding warnings for corrupted or unreadable files

Example outputs:

logs/ffprobe_failures.log
logs/bad_files.log

## 3. Improve classification accuracy

Enhance heuristics to correctly detect:

### Personal recordings

Detect:

- Timestamp filenames
- Capture directories
- Short clips (<20 minutes)

Example paths:

SteamLibrary
Content/Movies
OBS recordings
Game captures

### TV episodes

Detect additional patterns:

S01E01
1x01
Ep01
Episode 01

Duration heuristics:

18–75 minutes → likely TV

### Movie shorts / cartoons

Short films and cartoons often fall between:

5–18 minutes

Examples:

Looney Tunes
MGM shorts
Classic cartoons

These can be classified as:

Movie_Short

### TV specials

Items between:

35–70 minutes

Without episode naming may be classified as:

TV_Special

## 4. Generate a USB plan CSV

After scanning and classification, generate:

data/usb_plan.csv

Columns:

Kind
Title
Year
Show
Season
Episode
SourcePath
TargetPath

This becomes the **copy blueprint** for the USB drive.

## 5. Build the USB drive

Recommended filesystem:

exFAT

Reason:

- Handles large files (>4GB)
- Compatible with most TVs

### Suggested folder layout

USB_DRIVE/
│
├─ Movies/
│ ├─ Title (Year)/
│ │ └─ Title (Year).mkv
│
├─ TV/
│ ├─ Show Name/
│ │ ├─ Season 01/
│ │ │ └─ Show Name - S01E01 - Episode Title.mkv
│
└─ TV_Bundles/
└─ Show Name/
└─ Season 01.tar

### Copy process

Use `robocopy` for reliable transfer:

robocopy "D:\MediaSource" "E:\MediaUSB" /E /R:3 /W:5 /LOG:logs/usb_copy.log

Advantages:

- Resumable
- Handles large files well
- Generates logs

## 6. Backup to Google Drive

After organizing and validating the media inventory, upload important originals or bundles to Google Drive.

Options:

### Simple

Use **Google Drive for Desktop** and drag/drop.

### Advanced

Use **rclone** for scripted uploads.

Benefits of rclone:

- Resumable uploads
- Scheduled backups
- CLI automation

---

# Final goal

Create a **self-contained offline media library** that:

- Works directly in a TV’s USB media browser
- Is easy for non-technical users
- Is backed up to cloud storage
- Can be regenerated automatically from your archive
