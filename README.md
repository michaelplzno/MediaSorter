<!-- @format -->

# MediaSorter

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
- 📊 **CSV export** for easy filtering, planning, and analysis
- 🔍 **Metadata extraction** using ffprobe (duration, resolution, file size)
- 📦 **Archive support** for `.tar` season bundles
- 🔧 **Customizable** classification rules and heuristics
- 📝 **Error logging** for problematic files

## Prerequisites

- **Windows** with PowerShell 5.1 or later
- **ffprobe** (part of FFmpeg) installed and available in PATH
  - Download from: https://ffmpeg.org/download.html
  - Verify installation: `ffprobe -version`

## Getting Started

### 1. Configuration

Before running the scripts, configure your source drive paths. Each script file includes variables at the top that you'll need to customize:

```powershell
# Example - Edit these values at the top of your script
$SourceDrive = "E:\"  # Your media library drive letter
$OutputPrefix = "E"   # Prefix for output CSV files
```

**Available scripts:**
- `MediaSorter-Ddrive.ps1` - Example script (rename and configure for your drive)
- `MediaSorter-XDrive.ps1` - Example script (rename and configure for your drive)

**To customize:**
1. Copy one of the example scripts or create your own
2. Edit the `$SourceDrive` variable to point to your media drive
3. Edit the `$OutputPrefix` variable to name your output files
4. Save the script with a descriptive name (e.g., `MediaSorter-MyDrive.ps1`)

### 2. Run the Scanner

```powershell
# Navigate to the project directory
cd e:\Dev\MediaSorter

# Run your configured script
.\MediaSorter-MyDrive.ps1
```

The script will:
1. Recursively scan all video files and archives on your specified drive
2. Extract metadata with ffprobe for each file
3. Apply classification heuristics
4. Generate CSV output files

### 3. Review Output

After scanning completes, you'll find CSV files in the project directory:

- `{Prefix}_media_items.csv` - All media items with metadata and classification
- `{Prefix}_media_seasons_detected.csv` - Detected TV season information
- `{Prefix}_media_enriched.csv` - Enhanced classification results

## Classification Logic

MediaSorter uses intelligent heuristics to classify media:

### Movies
- Single large video files (typically >75 minutes)
- Common naming patterns with year indicators
- Classified as `Movie`

### TV Episodes
- Files with episode patterns: `S01E01`, `1x01`, `Episode 01`, `Ep01`
- Duration typically 18-75 minutes
- Classified as `TV_Episode`

### TV Season Archives
- `.tar` files with season indicators in the filename
- Classified as `TV_SeasonBundle`

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

### Archive Detection

- `.tar` movie bundles may not be reliably detected
- Work in progress to improve archive classification beyond TV seasons


## Output Structure

### Generated CSV Files

Each CSV contains the following key columns:

| Column | Description |
|--------|-------------|
| FullPath | Absolute path to the file |
| FileName | File name with extension |
| Extension | File extension (.mkv, .mp4, .tar, etc.) |
| SizeGB | File size in gigabytes |
| Duration | Runtime in minutes (video files only) |
| Width | Video width in pixels |
| Height | Video height in pixels |
| Kind | Classification type (Movie, TV_Episode, Personal, etc.) |
| Show | TV show name (if applicable) |
| Season | Season number (if applicable) |
| Episode | Episode number (if applicable) |


## Usage Examples

### Scan Multiple Drives

```powershell
# Configure and run separate scripts for each drive
.\MediaSorter-DriveE.ps1
.\MediaSorter-DriveF.ps1
.\MediaSorter-DriveG.ps1
```

### Analyze Results with PowerShell

```powershell
# Import and filter movies only
$movies = Import-Csv "E_media_items.csv" | Where-Object { $_.Kind -eq "Movie" }

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
