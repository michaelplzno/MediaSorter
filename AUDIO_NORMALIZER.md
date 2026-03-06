<!-- @format -->

# Audio Track Normalizer

`NormalizeAudioTracks.ps1` scans video files and normalizes audio streams so German tracks are removed and English is set as the default audio track.

The script uses `ffmpeg` stream copy (`-c copy`) by default, so it remuxes containers without re-encoding video/audio unless you later choose to re-encode a problem file manually.

## What It Does

- Scans media files recursively under a root folder/drive.
- Detects audio stream language using stream tags and title hints.
- Removes German audio streams (`de`, `deu`, `ger`, `German`, `Deutsch`).
- Sets exactly one default audio stream, preferring English (`en`, `eng`, `English`).
- Skips files that would become silent after removing German tracks.
- Skips files that have no English track after German removal (unless overridden).
- Writes timestamped run logs under `logs/`.

## Requirements

- Windows PowerShell 5.1+
- `ffprobe` in PATH
- `ffmpeg` in PATH

Quick checks:

```powershell
ffprobe -version
ffmpeg -version
```

## Usage

### Preview First (Recommended)

```powershell
cd e:\Dev\MediaSorter
.\NormalizeAudioTracks.ps1 -RootPath "F:\" -DryRun
```

### Apply Changes

```powershell
.\NormalizeAudioTracks.ps1 -RootPath "F:\"
```

### Keep Backups of Originals

```powershell
.\NormalizeAudioTracks.ps1 -RootPath "F:\" -KeepBackup
```

Backups are created next to each file with `.audiofix.bak` suffix.

### Process Specific Extensions Only

```powershell
.\NormalizeAudioTracks.ps1 -RootPath "F:\TV" -Extensions @('.mkv', '.mp4')
```

### Allow Non-English Fallback

By default, files are skipped if no English track remains after removing German tracks.

```powershell
.\NormalizeAudioTracks.ps1 -RootPath "F:\" -AllowWithoutEnglish
```

With this flag, the script will still remove German tracks and set the first remaining non-German track as default.

## Suggested Workflow with DriveBuilder

1. Build/export your drive as usual.
2. Run a dry-run normalization pass.
3. Run the real normalization pass.
4. Spot check a few files on the target TV/player.

```powershell
.\DriveBuilder.ps1 -DestinationDrive "F:\"
.\NormalizeAudioTracks.ps1 -RootPath "F:\" -DryRun
.\NormalizeAudioTracks.ps1 -RootPath "F:\"
```

## Logs

Each run creates:

- `logs/audio_normalizer_YYYYMMDD_HHMMSS.log`
- `logs/audio_normalizer_errors_YYYYMMDD_HHMMSS.log` (only when errors occur)

## Manual One-File Command (If You Need to Troubleshoot)

```powershell
ffmpeg -hide_banner -y -i "input.mkv" -map 0 -map -0:a:m:language:deu -map -0:a:m:language:ger -c copy -disposition:a:0 default "output.mkv"
```

Use this for one-off troubleshooting when you want to test behavior on a single file before running the script across a full drive.
