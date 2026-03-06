<!-- @format -->

# TheScrubber - Media Filename Cleanup Utility

## Overview

TheScrubber is a PowerShell utility that removes "garbage words" from media filenames and folder names. These garbage words include quality indicators, codecs, release group info, and other technical metadata that clutter up your media library.

## What It Does

### Step 1: Scan

- Scans the target drive for all video files and folders
- Identifies garbage words in filenames (1080p, x265, BluRay, etc.)
- Generates statistics on what was found
- Creates a report of all garbage words and their frequency

### Step 2: Clean

- Renames files and folders to remove garbage words
- Preserves the meaningful parts of filenames (show name, episode info)
- Cleans up extra delimiters and spacing
- Logs all operations for reference

## Garbage Words Detected

TheScrubber identifies and removes these categories of garbage words:

### Languages

`GERMAN`, `DUTCH`, `FRENCH`, `SPANISH`, `ITALIAN`, `JAPANESE`, `RUSSIAN`, `POLISH`, `PORTUGUESE`, `KOREAN`, `CHINESE`, `NORDIC`, `SWEDISH`, `NORWEGIAN`, `FINNISH`, `TURKISH`

### Quality/Source

`BluRay`, `BDRip`, `BRRip`, `Remux`, `WEB-DL`, `WEBRip`, `HDTV`, `DVDRip`, `WebHD`, `HDCAM`, `CAM`, `TS`, `TC`, `DVDSCR`, `SCREENER`, `PDTV`, `SDTV`, `DSR`, `HDRip`, `PPVRip`, `VHSRip`, `VODRip`, `AMZN`, `NF`, `DSNP`, `HMAX`, `ATVP`

### Resolution

`1080p`, `720p`, `2160p`, `4K`, `480p`, `576p`, `360p`, `240p`, `UHD`, `FHD`, `HD`, `SD`, `8K`

### Video Codecs

`x264`, `x265`, `h264`, `h265`, `HEVC`, `AVC`, `XviD`, `DivX`, `VP8`, `VP9`, `AV1`, `MPEG2`, `MPEG4`, `10bit`, `8bit`

### Audio Codecs

`AAC`, `AC3`, `DTS`, `TrueHD`, `Atmos`, `EAC3`, `DD5`, `DDP5`, `MP3`, `FLAC`, `DD51`, `DTS-HD`, `DTSHD`, `MA`, `DD`, `DDP`, `DD+`, `E-AC-3`

### Release Info

`iNTERNAL`, `PROPER`, `REPACK`, `LIMITED`, `UNRATED`, `EXTENDED`, `DIRECTORS`, `CUT`, `COMPLETE`, `FULL`, `SEASON`, `SERIES`, `REMASTERED`, `RETAIL`, `RERIP`, `UNCUT`, `THEATRICAL`

### Audio/Subtitle Options

`MULTi`, `DUAL`, `SUBBED`, `DUBBED`, `DL`, `SUBS`, `MULTISUBS`

## Usage

### Basic Scan (Recommended First Step)

```powershell
.\TheScrubber.ps1 -ScanOnly
```

Scans F: drive and shows what would be cleaned without making changes.

### Dry Run (See What Would Change)

```powershell
.\TheScrubber.ps1 -DryRun
```

Shows exactly what files and folders would be renamed without actually renaming them.

### Full Rename

```powershell
.\TheScrubber.ps1
```

Performs the actual rename operations on F: drive.

### Custom Drive

```powershell
.\TheScrubber.ps1 -TargetDrive "E:\" -DryRun
```

Scans and cleans a different drive.

### Interactive Mode

```powershell
.\TheScrubber.ps1 -Interactive
```

Asks for confirmation before each rename operation.

### Custom Garbage Words

```powershell
.\TheScrubber.ps1 -CustomNoiseWordsFile "my_garbage_words.txt"
```

Loads additional garbage words from a text file (one word per line).

## Parameters

| Parameter              | Type   | Default | Description                                          |
| ---------------------- | ------ | ------- | ---------------------------------------------------- |
| `TargetDrive`          | string | `F:\`   | The drive or path to scan and clean                  |
| `ScanOnly`             | switch | false   | Only scan and report, don't rename anything          |
| `DryRun`               | switch | false   | Show what would be renamed without actually renaming |
| `CustomNoiseWordsFile` | string | ""      | Path to a text file with additional garbage words    |
| `Interactive`          | switch | false   | Ask for confirmation before each rename              |

## Examples

### Example 1: Initial Assessment

```powershell
.\TheScrubber.ps1 -ScanOnly
```

**Output:**

```
SCAN RESULTS
============================================================
Folders:
  Total folders scanned:           245
  Folders with garbage words:      87

Files:
  Total video files scanned:       1,523
  Files with garbage words:        1,245

Garbage Words Found (Top 20):
  1080p                : 856 occurrences
  x264                 : 623 occurrences
  BluRay               : 445 occurrences
  ...
```

### Example 2: Before and After

**Before:**

```
F:\TV Shows\The.Office.S01E01.1080p.BluRay.x265.HEVC-PSA\
    The.Office.S01E01.Pilot.1080p.BluRay.x265.HEVC.AAC-PSA.mkv
```

**After:**

```
F:\TV Shows\The Office S01E01\
    The Office S01E01 Pilot.mkv
```

### Example 3: Complex Cleanup

**Before:**

```
Breaking.Bad.S05E16.Felina.1080p.WEB-DL.DD5.1.H.264-BS[rarbg].mkv
```

**After:**

```
Breaking Bad S05E16 Felina.mkv
```

## Workflow Recommendations

### First Time Use

1. **Run scan only**: `.\TheScrubber.ps1 -ScanOnly`
2. **Review the garbage words found** in `logs\garbage_words_found.txt`
3. **Run dry run**: `.\TheScrubber.ps1 -DryRun`
4. **Review a few examples** to make sure changes look good
5. **Execute full rename**: `.\TheScrubber.ps1`

### Ongoing Use

- Run after adding new media to keep library clean
- Use with other MediaSorter tools for complete organization

## Logs and Reports

TheScrubber creates several log files in the `logs` folder:

### Scan Log

`logs\scrubber_scan_YYYYMMDD_HHMMSS.log`

- Timestamp of each operation
- Items scanned and analyzed
- Errors encountered during scan

### Rename Log

`logs\scrubber_rename_YYYYMMDD_HHMMSS.log`

- Complete record of all rename operations
- Old path → New path for each item
- Errors encountered during rename

### Garbage Words Report

`logs\garbage_words_found.txt`

- Complete list of all garbage words found
- Frequency count for each word
- Sorted by occurrence count

## Safety Features

### Collision Detection

TheScrubber checks if the target filename already exists before renaming. If it does, the operation is skipped and logged as an error.

### Preservation of Extensions

File extensions are never modified, only the filename portion is cleaned.

### Depth-First Folder Processing

Folders are renamed from deepest to shallowest to avoid path invalidation issues.

### Comprehensive Logging

Every operation (success or failure) is logged for audit purposes.

## Integration with MediaSorter

TheScrubber complements the MediaSorter ecosystem:

1. **MediaSorter.ps1** - Analyzes and categorizes media
2. **TheScrubber.ps1** - Cleans up filenames (run this first!)
3. **DriveBuilder.ps1** - Exports organized media to external drives
4. **NormalizeAudioTracks.ps1** - Normalizes audio levels

### Recommended Order

```powershell
# 1. Clean up filenames first
.\TheScrubber.ps1 -TargetDrive "D:\" -DryRun
.\TheScrubber.ps1 -TargetDrive "D:\"

# 2. Then analyze and categorize
.\MediaSorter.ps1 -RootPath "D:\"

# 3. Finally export to external drive
.\DriveBuilder.ps1 -DestinationDrive "F:\"
```

## Advanced Usage

### Custom Garbage Words File

Create a text file with additional words to remove:

**my_garbage_words.txt:**

```
YIFY
YTS
RARBG
TGx
GalaxyTV
```

Then use it:

```powershell
.\TheScrubber.ps1 -CustomNoiseWordsFile "my_garbage_words.txt"
```

### Batch Processing Multiple Drives

```powershell
$drives = @("D:\", "E:\", "F:\")
foreach ($drive in $drives) {
    Write-Host "Processing $drive..."
    .\TheScrubber.ps1 -TargetDrive $drive
}
```

## Technical Details

### Pattern Matching

TheScrubber uses word boundary matching to avoid false positives. For example:

- ✅ Removes: `The.Show.S01E01.x264.mkv` → `The Show S01E01.mkv`
- ✅ Preserves: `District.9.mkv` (doesn't match "DISTRICT" garbage word)

### Bracket Removal

Content in brackets that contains garbage words is entirely removed:

- `[1080p]` → removed
- `(x265)` → removed
- `{HEVC}` → removed

### Delimiter Cleanup

Multiple delimiters are normalized:

- `Show..Name..S01E01` → `Show.Name.S01E01`
- `Show_-_Name` → `Show Name`
- Trailing delimiters before extension are removed

## Troubleshooting

### "Target already exists" Errors

**Cause:** Two different files clean up to the same name.

**Example:**

- `Show.S01E01.1080p.mkv` → `Show S01E01.mkv`
- `Show.S01E01.720p.mkv` → `Show S01E01.mkv` (collision!)

**Solution:** Manual review required. Check the rename log to identify conflicts, then rename one of the files manually before running TheScrubber.

### Permission Errors

**Cause:** Files are in use or you lack permissions.

**Solution:**

- Close any media players or explorers with those files open
- Run PowerShell as Administrator
- Check file/folder permissions

### Too Many False Positives

**Cause:** A garbage word matches part of a legitimate show name.

**Solution:** Edit the script to remove that word from the `$script:garbageWords` array, or use `-ScanOnly` first to review.

## Performance

Typical performance on modern hardware:

- **Scan rate:** ~500-1000 files/second
- **Rename rate:** ~100-200 files/second
- **Example:** 10,000 files = ~2-3 minutes total

## Version History

### v1.0 (2026-03-06)

- Initial release
- Two-step scan and clean process
- Comprehensive garbage word list
- Interactive mode support
- Dry run capability
- Custom noise words support

## See Also

- [MediaSorter.ps1](README.md) - Main media analysis tool
- [DriveBuilder.ps1](DRIVE_BUILDER.md) - Export organized media
- [NormalizeAudioTracks.ps1](AUDIO_NORMALIZER.md) - Audio normalization
