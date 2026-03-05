<!-- @format -->

# MICHAELplzno MediaSorter

A PowerShell-based tool for scanning, classifying, and organizing large media libraries into structured formats suitable for USB media players, TV playback, and cloud backup.

## Overview

MediaSorter helps you organize personal media collections by:

- **Scanning** video files and archives recursively across drives
- **Extracting** metadata (duration, resolution) using ffprobe
- **Classifying** content automatically (Movies, TV Episodes, Personal recordings, etc.)
- **Exporting** structured CSV inventories for planning and organization
- **Supporting** multiple media types including `.tar` season bundles

Perfect for creating offline media libraries on USB drives for non-smart TVs, organizing archived Blu-ray/DVD collections, or preparing media for cloud backup.

## Features

- 🎬 **Automatic classification** of movies, TV episodes, personal recordings, and archives
- � **Archive analysis** with size-based heuristics to identify movie vs TV season bundles
- 🔗 **Smart grouping** of loose episodes into virtual season bundles (e.g., multiple South Park episodes → Season 1)
- 🔍 **Duplicate detection** between archives and extracted files to avoid double-counting
- 📊 **CSV export** for easy filtering, planning, and analysis
- 🎯 **Metadata extraction** using ffprobe (duration, resolution, file size)
- 🏷️ **Episode parsing** extracts show name, season, and episode numbers from filenames
- 🔧 **Customizable** classification rules and heuristics
- 📝 **Error logging** for problematic files

## Prerequisites

- **Windows** with PowerShell 5.1 or later
- **ffprobe** (part of FFmpeg) installed and available in PATH
  - Download from: https://ffmpeg.org/download.html
  - Verify installation: `ffprobe -version`

## Getting Started

### 1. Run the Scanner

```powershell
# Navigate to the project directory
cd e:\Dev\MediaSorter

# Scan a specific drive (defaults to D:\ if not specified)
.\MediaSorter.ps1 -RootPath "D:\"

# Scan other drives
.\MediaSorter.ps1 -RootPath "E:\"
.\MediaSorter.ps1 -RootPath "X:\"

# Or scan a specific folder
.\MediaSorter.ps1 -RootPath "C:\Videos\MyCollection"
```

**Parameters:**

- `-RootPath` (optional): Drive letter or folder path to scan (default: `"D:\"`)

**Output files:**

- CSV files are automatically named based on the drive letter (e.g., scanning `D:\` creates `D_media_*.csv`)
- Scanning `E:\` creates `E_media_*.csv`, etc.

The script will:

1. Recursively scan all video files and archives on your specified drive or folder
2. Extract metadata with ffprobe for each file
3. Apply classification heuristics
4. Detect and group loose episodes into virtual season bundles
5. Identify duplicates between archives and extracted files
6. Generate CSV output files

### 2. Review Output

After scanning completes, you'll find CSV files in the project directory:

- `{Prefix}_media_items.csv` - All media items with metadata, classification, and grouping info
- `{Prefix}_media_seasons_detected.csv` - Detected TV season folders
- `{Prefix}_media_groups.csv` - Virtual season bundles (loose episodes grouped together)
- `{Prefix}_media_duplicates.csv` - Detected duplicates between archives and extracted files

## Classification Logic

MediaSorter uses intelligent heuristics to classify media:

### Movies

- Single large video files (typically >75 minutes)
- Common naming patterns with year indicators
- Classified as `Movie`

### TV Episodes

- Files with episode patterns: `S01E01`, `1x01`, `Episode 01`, `Ep01`, `E01` (standalone)
- Season patterns: `SXX` where XX < 40 (e.g., `S01`, `S25`, but not `S45`)
- Duration typically 18-75 minutes
- Classified as `TV_Episode`

### Enhanced Parsing Features

MediaSorter uses intelligent parsing to extract clean show names:

- **Case-insensitive matching**: All pattern detection ignores case
- **Multiple delimiters**: Treats `.`, `_`, `-`, and space as equivalent separators
- **Year detection**: Recognizes 4-digit years starting with 19 or 20 (1900-2099) as delimiters
- **Noise word filtering**: Automatically removes quality tags and release info:
  - Language tags: `GERMAN`, `DUTCH`, `FRENCH`, `JAPANESE`, etc.
  - Quality indicators: `BluRay`, `WEB-DL`, `HDTV`, `1080p`, `720p`, `4K`, etc.
  - Codecs: `x264`, `x265`, `h264`, `HEVC`, `AAC`, `DTS`, etc.
  - Release tags: `iNTERNAL`, `PROPER`, `REPACK`, `LIMITED`, etc.
  - Other: `COMPLETE`, `DUAL`, `DL`, `MULTi`, etc.
- **Delimiter-based extraction**: Takes everything BEFORE episode/season/year patterns as the show name

**Example parsing:**

- `South.Park.S25E05.iNTERNAL.1080p.WEB.h264-OPUS.mkv` → Show: `South Park`, Season: `S25`, Episode: `E05`
- `The.Lazarus.Project.S01E01.German.AC3.DL.1080p.WebHD.x265-FuN.mkv` → Show: `The Lazarus Project`, Season: `S01`, Episode: `E01`
- `Show.Name.2020.720p.BluRay.x264.mkv` → Everything before `2020` becomes the show name (if episode pattern exists)

### TV Season Archives

- `.tar`, `.zip`, `.7z` and other archive files analyzed by size and naming patterns
- Size heuristics: 3-15 GB (likely movie), 25+ GB (likely full TV season)
- Season indicators: `S01`, `Season 1`, `Complete` keywords
- Classified as `TV_SeasonBundle`, `Movie_Archive`, or `Archive_Ambiguous`

### Virtual Season Bundles

- Loose video episodes (3+ files) automatically grouped by show + season
- Example: `South.Park.S01E01.mkv`, `South.Park.S01E02.mkv`, etc. → Virtual Season 1 bundle
- Enables accurate season-level statistics even without folder organization

### Duplicate Detection

- Compares archives with extracted video files
- Matches by show name, season number, and file size ratios
- Marks potential duplicates to avoid double-counting storage

### Personal Content

- Short clips (<20 minutes without TV/movie indicators)
- Timestamp-based filenames (e.g., `2023-06-10 16-21-38.mp4`)
- Located in capture/recording directories (e.g., OBS, SteamLibrary)
- Classified as `Personal`

### Unknown

- Files that don't match any classification rules
- Review these manually and adjust classification rules as needed

## Known Issues & Limitations

### Classification Edge Cases

Some items may be misclassified due to:

- Non-standard naming conventions (anime, foreign media)
- Ambiguous durations (short films, TV specials, cartoons)
- Mixed content types in the same directory

**Solution:** Review CSV output and manually adjust classification rules in the script as needed.

### FFprobe Failures

Files showing zero values for duration/resolution may indicate:

- Corrupted or zero-byte files
- Unsupported or unusual formats
- File permission issues
- Bad paths or broken symlinks

**Solution:** Check error logs and verify file integrity. Consider excluding problematic directories.

## Output Structure

### Generated CSV Files

Each CSV contains the following key columns:

| Column       | Description                                               |
| ------------ | --------------------------------------------------------- |
| ItemType     | Type: VideoFile or Archive                                |
| FullPath     | Absolute path to the file                                 |
| FileName     | File name with extension                                  |
| Extension    | File extension (.mkv, .mp4, .tar, etc.)                   |
| SizeGB       | File size in gigabytes                                    |
| DurationMin  | Runtime in minutes (video files only)                     |
| Width        | Video width in pixels                                     |
| Height       | Video height in pixels                                    |
| AutoCategory | Classification (Movie, TV_Episode, TV_SeasonBundle, etc.) |
| Confidence   | Classification confidence score (0-100)                   |
| ShowName     | Extracted TV show name                                    |
| SeasonNum    | Season number (S01, S02, etc.)                            |
| EpisodeNum   | Episode number (E01, E02, etc.)                           |
| GroupID      | ID linking related files (virtual bundles, duplicates)    |
| GroupType    | Type: Virtual_SeasonBundle, Duplicate_Archive, etc.       |
| DuplicateOf  | Reference to duplicate file if detected                   |
| Episode      | Episode number (if applicable)                            |

## Usage Examples

### Scan Multiple Drives

```powershell
# Scan different drives with one command each
.\MediaSorter.ps1 -RootPath "D:\"
.\MediaSorter.ps1 -RootPath "E:\"
.\MediaSorter.ps1 -RootPath "F:\"
```

### Analyze Results with PowerShell

```powershell
# Import and filter movies only
$movies = Import-Csv "D_media_items.csv" | Where-Object { $_.AutoCategory -eq "Movie" }

# Find all Star Trek episodes
$trek = Import-Csv "E_media_items.csv" | Where-Object { $_.Show -like "*Star Trek*" }

# Calculate total library size in GB
$total = (Import-Csv "E_media_items.csv" | Measure-Object -Property SizeGB -Sum).Sum
Write-Host "Total library size: $total GB"

# Find all Unknown classifications for manual review
$unknown = Import-Csv "E_media_items.csv" | Where-Object { $_.Kind -eq "Unknown" }
```

### Filter with Excel

Open the CSV files in Excel or Google Sheets and use filters to:

- Sort by Kind, Show, Duration, or Size
- Create pivot tables for library statistics
- Plan what content to include on USB drives

## Building a USB Media Library

Once you've scanned and reviewed your media inventory:

### 1. Filter Content

Use the CSV files to decide which movies and shows to include on your USB drive.

### 2. Choose Filesystem

Use **exFAT** format for your USB drive:

- Supports files larger than 4GB (FAT32 limit)
- Compatible with most modern TVs and media players
- Works across Windows, Mac, and Linux

### 3. Organize with a Clear Structure

```
USB_DRIVE/
├─ Movies/
│  └─ Movie Title (Year)/
│     └─ Movie Title (Year).mkv
├─ TV/
│  └─ Show Name/
│     └─ Season 01/
│        ├─ Show Name - S01E01.mkv
│        └─ Show Name - S01E02.mkv
└─ TV_Bundles/
   └─ Show Name/
      └─ Season 01.tar
```

### 4. Copy Files Reliably

Use `robocopy` for reliable file transfers:

```powershell
# Example: Copy from source to USB drive
robocopy "E:\Media\Movies" "F:\Movies" /E /R:3 /W:5 /LOG:copy.log

# Parameters explained:
# /E - Copy subdirectories including empty ones
# /R:3 - Retry 3 times on failure
# /W:5 - Wait 5 seconds between retries
# /LOG - Create a log file
```

## Planned Features

- [ ] Enhanced classification with additional pattern detection
- [ ] Support for more archive formats (zip, rar, 7z)
- [ ] Automatic USB drive builder with one command
- [ ] Cloud backup integration (Google Drive, OneDrive, Backblaze)
- [ ] Duplicate detection and deduplication
- [ ] Format conversion pipeline for TV compatibility
- [ ] Web-based dashboard for inventory management
- [ ] Multi-language filename pattern support

## Contributing

Contributions are welcome! Areas for improvement:

- **Enhanced classification algorithms** - Better detection of edge cases
- **Archive format support** - Beyond .tar files
- **Multi-language patterns** - International media naming conventions
- **Performance optimizations** - Large library processing
- **TV compatibility testing** - Feedback on various TV brands/models

Please submit issues and pull requests on GitHub.

## Troubleshooting

### Script doesn't find ffprobe

**Error:** `The term 'ffprobe' is not recognized...`

**Solution:**

1. Install FFmpeg from https://ffmpeg.org/download.html
2. Add FFmpeg bin directory to your system PATH
3. Restart PowerShell and run `ffprobe -version` to verify

### Permission errors during scan

**Error:** `Access to the path '...' is denied`

**Solution:**

- Run PowerShell as Administrator
- Check file/folder permissions on source drive
- Exclude system directories that require special permissions

### Script runs very slowly

**Causes:**

- Large libraries (10,000+ files) take time to process
- Network drives are slower than local drives
- ffprobe extraction is CPU-intensive

**Solutions:**

- Be patient - first scan is always slowest
- Exclude directories you don't need to scan
- Run overnight for very large libraries

### Classification is inaccurate

**Solution:**

- Review the CSV output to identify patterns
- Modify the classification rules in the script
- Submit an issue with examples for community help

## License

MIT License - Feel free to use and modify for personal or commercial projects.

## Support

If you encounter issues:

1. **Check prerequisites** - Ensure ffprobe is installed and in PATH
2. **Verify configuration** - Double-check drive paths in your script
3. **Review CSV output** - Look for patterns in misclassified files
4. **Check file permissions** - Ensure you have read access to source media
5. **Submit an issue** - Include error messages and examples on GitHub

## Acknowledgments

Built with PowerShell and ffprobe for media enthusiasts who want to:

- Organize large personal media collections
- Create offline media libraries for TVs without smart features
- Preserve physical media collections digitally
- Share curated content with family and friends

Perfect for cord-cutters, media archivists, and anyone who values owning their media library.
