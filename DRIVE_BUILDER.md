<!-- @format -->

# Drive Builder

The Drive Builder script copies media files from your MediaSorter CSV files to a destination drive (USB flash drive, external drive, etc.) with automatic organization and archive extraction.

## Features

- **Multi-source CSV support**: Reads from multiple media CSV files (e.g., `D_media_items.csv`, `X_media_items.csv`)
- **Automatic organization**: Organizes files into folders by category:
  - `TV/` - TV episodes organized by show name
  - `Movies/` - Movie files
  - `Clips/` - Clip files only
- **Category policy**: Skips `Personal` and `Unknown` items (kept out of export until categorized)
- **Archive extraction**: Automatically extracts `.tar`, `.tar.gz`, `.tar.xz`, and `.tar.zst` archives (TVs can't read tar files directly)
- **Live transfer speed**: Shows current copy speed in `MB/s` during file copy operations
- **Per-file progress**: Updates continuously while large files copy (file percent and total export percent)
- **Space checking**: Verifies the drive has enough free space before copying and gracefully reports if space is insufficient
- **Fail-fast error handling**: Stops immediately on first error and writes the error to terminal and `logs/drive_builder_errors.log`

## Usage

### Basic Usage

```powershell
.\DriveBuilder.ps1 -DestinationDrive "E:\"
```

### With Multiple Source CSVs

```powershell
.\DriveBuilder.ps1 -DestinationDrive "F:\" -SourceCsvPatterns @("D_media_items.csv", "X_media_items.csv")
```

### Dry Run (Preview)

```powershell
.\DriveBuilder.ps1 -DestinationDrive "F:\" -DryRun
```

## Parameters

| Parameter            | Required | Default             | Description                                                 |
| -------------------- | -------- | ------------------- | ----------------------------------------------------------- |
| `-DestinationDrive`  | Yes      | N/A                 | Target drive path (e.g., `E:\`, `F:\`, `E:\path\to\folder`) |
| `-SourceCsvPatterns` | No       | `*_media_items.csv` | Array of CSV file patterns to read from                     |
| `-DryRun`            | No       | False               | Preview mode - shows what would be copied without copying   |

## Examples

### Copy to USB Flash Drive

```powershell
# Dry run first to see what will be copied
.\DriveBuilder.ps1 -DestinationDrive "E:\" -DryRun

# Then do the actual copy
.\DriveBuilder.ps1 -DestinationDrive "E:\"
```

### Copy Specific Media Sources

```powershell
# Copy only D: and X: drive scans
.\DriveBuilder.ps1 -DestinationDrive "F:\" `
  -SourceCsvPatterns @("D_media_items.csv", "X_media_items.csv")
```

### Copy to External Drive Folder

```powershell
# Creates TV/, Movies/, Clips/ inside the folder
.\DriveBuilder.ps1 -DestinationDrive "E:\MyMediaBackup"
```

## Partial Drive Support (Resumable Copies)

The Drive Builder gracefully handles partially-complete drives. If your copy operation is interrupted, you can re-run the script with the same parameters and it will:

1. **Scan for existing files** - Checks which files are already on the destination
2. **Validate existing files** - Confirms copied files are complete before skipping
3. **Repair partial transfers** - Removes incomplete artifacts and redoes those items
4. **Preserve progress** - Allows you to resume without wasting time or space

### Example Workflow

```powershell
# First run - copy starts but gets interrupted after 30 GB
.\DriveBuilder.ps1 -DestinationDrive "F:\"
# (Ctrl+C after 30 files copied)

# No problem! Just re-run the same command
.\DriveBuilder.ps1 -DestinationDrive "F:\"
# Script automatically detects 30 files are already there and continues with the rest

# Or preview what will happen
.\DriveBuilder.ps1 -DestinationDrive "F:\" -DryRun
# Output will show:
#   Files already on destination: 30
#   New files to copy: 170
#   Data to copy: 450 GB
```

### Partial Drive Detection

The script detects existing files by:

- **Regular files**: Requires matching filename, matching byte size, and no partial copy artifact
- **Extracted archives**: Requires extraction folder plus a completion marker file

The script also detects and repairs interrupted artifacts:

- `filename.ext.__partial_copy__` temp files left from interrupted copies
- `ExtractFolder.__partial_extract__` temp folders left from interrupted archive extraction
- Archive folders that exist without a completion marker

If any of these are found, the item is treated as incomplete and is copied/extracted again.

## Drive Validation and Space Checking

## Output Structure

```
[DestinationDrive]/
├── TV/
│   ├── Show Name 1/
│   │   ├── episode01.mkv
│   │   └── episode02.mkv
│   └── Show Name 2/
│       └── episode01.mkv
├── Movies/
│   ├── Movie 1.mkv
│   └── Movie 2.mkv
└── Clips/
    ├── clip1.mp4
    ├── clip2.mp4
  └── clip3.avi
```

## Archive Handling

Archives are automatically extracted to a folder with the archive's base name:

```
TV/
└── Show Name/
    └── processed_archive_name/
        ├── extracted_episode1.mkv
        └── extracted_episode2.mkv
```

Supported archive formats:

- `.tar`
- `.tar.gz` / `.tgz`
- `.tar.xz`
- `.tar.zst`

## Requirements

For compressed archives (`.tar.gz`, `.tar.xz`, `.tar.zst`):

- **Recommended**: 7-Zip installed at `C:\Program Files\7-Zip\7z.exe`
- **Fallback**: Windows 10/11 with native `tar` command support
- **Alternative**: PowerShell 7+ for full tar support

## Logging

- `logs/drive_builder.log` - All operations
- `logs/drive_builder_errors.log` - Errors only (if any)

## Category Mapping

Files are organized based on their `AutoCategory` from the media scan:

| AutoCategory | Destination      |
| ------------ | ---------------- |
| TV_Episode   | `TV/[ShowName]/` |
| TV_Season    | `TV/[ShowName]/` |
| TV           | `TV/[ShowName]/` |
| Movie        | `Movies/`        |
| Clip         | `Clips/`         |

Excluded from export:

| AutoCategory | Behavior |
| ------------ | -------- |
| Personal     | Skipped  |
| Unknown      | Skipped  |

## Tips

1. **Always run with `-DryRun` first** to verify what will be copied
2. **Use exact drive letters** for removable drives (e.g., `E:\` not `E:`)
3. **Check log files** after copying to ensure everything completed successfully
4. **Leave some space** for potential archive expansion during extraction
5. **Safe interrupts**: It's safe to interrupt the script with Ctrl+C - just re-run with the same parameters to resume
6. **Partial drives are okay**: If your copy is interrupted, run the script again and it will gracefully skip files already present
7. **Verify with dry-run after interrupt**: Use `-DryRun` to check what still needs copying before resuming

## Troubleshooting

### "Source file not found"

- The script now aborts immediately on the first missing source file (fail-fast behavior)
- Verify that the media items still exist at the paths in the CSV
- Check that the CSV files reference valid paths

### Archive extraction fails

- Ensure 7-Zip is installed for `.tar.gz` and `.tar.xz` files
- Check that the destination has enough free space
- Verify the archive file isn't corrupted

### Progress bar seems slow

- Large files and archives take time to copy
- Network drives are slower than local drives
- Archive extraction happens during the copy operation

### "Destination drive/path does not exist"

- Verify the destination drive letter is correct and mounted
- Check that the path is accessible and formatted correctly

### Script stops in the middle

The script can be safely stopped and resumed:

```powershell
# First run gets interrupted after some files
.\DriveBuilder.ps1 -DestinationDrive "F:\"
# Ctrl+C to stop

# Check what's left
.\DriveBuilder.ps1 -DestinationDrive "F:\" -DryRun

# Resume from where you left off
.\DriveBuilder.ps1 -DestinationDrive "F:\"
# Script will skip the already-copied files and continue
```

### How does the script know what's already copied?

The script checks for:

- **Files**: Destination file must exist and match the source byte size
- **Files**: Any `.__partial_copy__` file means the item is incomplete and will be redone
- **Extracted archives**: Extraction folder must exist and include `.drive_builder_extract_complete`
- **Extracted archives**: Any `.__partial_extract__` folder means the item is incomplete and will be redone

This means you can safely re-run the script after interruptions: complete transfers are skipped, incomplete ones are repaired automatically.

### "Destination drive appears to be formatted incorrectly or is not writable"

The script detected the drive cannot be written to. This can happen if:

**Solutions:**

1. **For USB flash drives**:

- Try reformatting the drive as NTFS, FAT32, or exFAT
- Right-click drive in File Explorer → Format

2. **Check if drive is read-only**:

- Some USB drives have a physical read-only switch - flip it
- In File Explorer, right-click drive → Properties, check "Read-only" checkbox

3. **Check permissions**:

- Run PowerShell as Administrator
- Verify you have write permissions to the drive

4. **Try a different USB port**:

- Sometimes USB ports have issues
- Try a different port on your computer

5. **If drive is corrupted**:

- The drive may need low-level formatting
- Consider replacing the drive if problems persist

### "INSUFFICIENT DISK SPACE"

The drive doesn't have enough free space for the copy.

**Solutions:**

1. **Delete files from the destination drive** - Remove files you no longer need to free up space
2. **Use a larger drive** - USB 3.0 drives up to 1TB+ are relatively inexpensive
3. **Copy in multiple batches** - Create multiple copies to different drives using `-SourceCsvPatterns`
4. **Check consumed space** - The script shows exactly how much is needed vs available

### Why dry-run shows insufficient space

The dry-run performs the same validation as the full copy, preventing wasted time on copies that would fail. Always use `-DryRun` first to verify space and format before committing.
