<!-- @format -->

# Drive Cloner

A PowerShell tool for creating verified clones of entire drives with cryptographic integrity verification and resume capability.

## Overview

DriveCloner creates an exact copy of a source drive to a destination drive, then generates MD5 hashes for all files on both drives and compares them to ensure the clone was successful. The tool supports resuming interrupted operations and provides detailed progress tracking throughout the cloning process.

## Features

- **Complete Drive Cloning**: Copies all files from source to destination while preserving directory structure
- **Space Verification**: Checks destination drive has sufficient space before starting
- **Hash-Based Verification**: Generates MD5 hashes for all files on both drives and compares them
- **Resume Capability**: Can resume interrupted clones by checking for existing files with valid hashes
- **Progress Tracking**: Detailed progress bars showing:
  - File-by-file copy progress with speed and ETA
  - Hash generation progress for both drives
  - Overall completion percentage
- **Integrity Cache**: Stores hashes in `.integrity_cache` folders (same structure as DriveBuilder)
- **Clone Manifest**: Creates `.drive_clone_manifest.csv` with all file hashes for the destination drive
- **Atomic Operations**: Uses partial file markers (`.\_\_partial_copy\_\_`) to ensure clean resume
- **Comprehensive Logging**: Creates detailed logs for operations, errors, and verification results

## File Filtering

DriveCloner is designed for media libraries and intelligently filters files during cloning:

### Included Files

Only common media file formats are copied:

- **Video formats**: .mkv, .mp4, .avi, .mov, .wmv, .flv, .webm, .m4v, .mpg, .mpeg, .m2ts, .ts, .vob, .ogv, .3gp, .divx
- **Audio formats**: .mp3, .flac, .m4a, .aac, .wav, .ogg, .wma, .opus, .alac, .ape

### Excluded Files/Folders

The following are automatically excluded:

- **$RECYCLE.BIN**: Windows recycle bin contents
- **`.integrity_cache`**: Hash cache folders (DriveBuilder/DriveCloner)
- **System files**: `.drive_builder_test`, `.drive_builder_extract_complete`, `.drive_builder_completed_archives`
- **Clone manifest**: `.drive_clone_manifest.csv`
- **Partial copies**: Files ending with `.\_\_partial_copy\_\_`
- **Non-media files**: Documents (.doc, .pdf), images (.jpg, .png), archives (.zip, .tar), executables (.exe), etc.

This ensures only actual media content is cloned, saving time and space.

## Usage

### Basic Clone

```powershell
.\DriveCloner.ps1 -SourceDrive "E:" -DestinationDrive "F:"
```

### Dry Run (Preview)

Preview what would be copied without actually copying:

```powershell
.\DriveCloner.ps1 -SourceDrive "E:" -DestinationDrive "F:" -DryRun
```

### Skip Hash Comparison

Copy files and generate hashes but skip the verification phase:

```powershell
.\DriveCloner.ps1 -SourceDrive "E:" -DestinationDrive "F:" -SkipHashComparison
```

### Force (Bypass Space Check)

Bypass the destination space check:

```powershell
.\DriveCloner.ps1 -SourceDrive "E:" -DestinationDrive "F:" -Force
```

### Resume an Interrupted Clone

Simply run the same command again. The tool will automatically skip files that have already been copied and have valid hashes:

```powershell
.\DriveCloner.ps1 -SourceDrive "E:" -DestinationDrive "F:"
```

## Parameters

| Parameter             | Type   | Required | Description                                                 |
| --------------------- | ------ | -------- | ----------------------------------------------------------- |
| `-SourceDrive`        | String | Yes      | Source drive path (e.g., "E:" or "E:\Folder")               |
| `-DestinationDrive`   | String | Yes      | Destination drive path (e.g., "F:")                         |
| `-DryRun`             | Switch | No       | Preview mode - shows what would be copied without copying   |
| `-SkipHashComparison` | Switch | No       | Skip the hash comparison phase (faster but no verification) |
| `-Force`              | Switch | No       | Bypass destination space check                              |

## Operation Phases

### Phase 1: Copying Files

1. Scans source drive for all files
2. Calculates total size and file count
3. Verifies destination has sufficient space (with 1GB safety margin)
4. For each file:
   - Checks if already copied (file exists with valid hash in cache)
   - Copies to destination with `.\_\_partial_copy\_\_` suffix
   - Verifies byte size matches source
   - Atomically renames to final name
   - Generates MD5 hash for destination file
   - Saves hash to `.integrity_cache` folder

### Phase 2: Generating Source Hashes

1. For each source file without a cached hash:
   - Computes MD5 hash
   - Saves to `.integrity_cache` folder on source drive
2. Reuses existing cached hashes to save time

### Phase 3: Verifying Hashes

1. For each file:
   - Loads source hash from cache
   - Loads destination hash from cache
   - Compares the two hashes
   - Logs results to verification log
2. Reports final verification status:
   - ✅ All files matched: Clone successful
   - ⚠️ Mismatches detected: Clone has integrity issues

## Output Files

### Logs

All logs are written to the `logs` folder:

- **`drive_cloner.log`**: Main operation log with timestamps
- **`drive_cloner_errors.log`**: Error details (only created if errors occur)
- **`drive_cloner_verification.log`**: Hash comparison results for each file

### Integrity Cache

Each drive gets a `.integrity_cache` folder structure that mirrors the file structure:

```
E:\
  ├── .integrity_cache\
  │   ├── Movies\
  │   │   └── MovieFile.mkv.md5
  │   └── TV\
  │       └── ShowFile.mkv.md5
  ├── Movies\
  │   └── MovieFile.mkv
  └── TV\
      └── ShowFile.mkv
```

Each `.md5` file contains:

- Line 1: MD5 hash (32 hex characters)
- Line 2: File size in bytes
- Line 3: Timestamp
- Line 4: Original filename

### Clone Manifest

The destination drive receives a `.drive_clone_manifest.csv` file at the root with columns:

- `RelativePath`: Path relative to destination root
- `Hash`: MD5 hash
- `FileSize`: Size in bytes
- `Timestamp`: When the hash was generated

This manifest enables quick verification of the clone without re-hashing.

## Resume Behavior

DriveCloner automatically resumes interrupted operations:

1. **File Copy Resume**: If a destination file exists with the same size and has a valid hash in `.integrity_cache`, the file is skipped
2. **Partial File Cleanup**: Files with `.\_\_partial_copy\_\_` suffix are cleaned up and re-copied
3. **Source Hash Reuse**: Source files that already have valid cached hashes are not re-hashed
4. **Manifest Loading**: If `.drive_clone_manifest.csv` exists, it's loaded to track previous progress

## Examples

### Clone a media drive

```powershell
.\DriveCloner.ps1 -SourceDrive "E:\Media" -DestinationDrive "F:"
```

### Test before cloning

```powershell
# Preview what would be cloned
.\DriveCloner.ps1 -SourceDrive "E:" -DestinationDrive "F:" -DryRun

# If satisfied, run the actual clone
.\DriveCloner.ps1 -SourceDrive "E:" -DestinationDrive "F:"
```

### Resume after interruption

```powershell
# First run (interrupted mid-way)
.\DriveCloner.ps1 -SourceDrive "E:" -DestinationDrive "F:"
# ... Process interrupted ...

# Resume (same command, will skip already-copied files)
.\DriveCloner.ps1 -SourceDrive "E:" -DestinationDrive "F:"
```

## Verification Results

The verification phase produces one of three results for each file:

- **OK**: Hashes match, file copied successfully
- **MISMATCH**: Hashes don't match, possible corruption
- **MISSING**: Hash file missing on source or destination

Final summary shows:

- Matched count (should equal total files for successful clone)
- Mismatched count (should be 0)
- Missing count (should be 0)

## Performance

- Uses 4MB buffer size for optimal I/O performance
- Progress updates every 250ms to balance responsiveness and overhead
- Hash computation happens in 4MB chunks with streaming to minimize memory usage
- Reuses cached hashes to avoid redundant computation on resume

## Integration with DriveBuilder

DriveCloner uses the same hash cache structure as DriveBuilder (`.integrity_cache` folders), making them fully compatible:

- If you clone a drive that was built with DriveBuilder, source hashes are reused
- If you later run DriveBuilder on a cloned drive, it will reuse DriveCloner's hashes
- Both tools use the same MD5 hash format and validation logic

## Error Handling

- **Space check failure**: Aborts if destination doesn't have enough space (use `-Force` to override)
- **Copy failure**: Logs error and continues with next file
- **Hash computation failure**: Logs error, file marked as unverified
- **Verification failure**: Reports mismatches but completes all checks
- **All errors logged**: Check `logs/drive_cloner_errors.log` for full details

## Safety Features

1. **Atomic Rename**: Files copied to `.\_\_partial_copy\_\_` first, renamed only after successful copy
2. **Size Verification**: Destination file size verified before rename
3. **Source Protection**: Source drive is read-only, never modified (except `.integrity_cache`)
4. **Progress Persistence**: Resume capability means you never lose progress
5. **Dry Run Mode**: Test operations before committing
6. **Space Safety Margin**: Requires 1GB extra free space beyond actual file size

## Troubleshooting

### "Insufficient space on destination drive"

- Check actual free space with `Get-PSDrive`
- Use `-Force` to bypass check if space calculation is incorrect
- Consider freeing up space or using a larger destination drive

### "Hash mismatch detected"

- May indicate:
  - File corruption during copy
  - Hardware issues with source or destination drive
  - File modified on source during cloning
- Re-run the clone to overwrite problematic files
- Run disk diagnostics on both drives

### Files not resuming properly

- Check that `.integrity_cache` folders exist and contain valid `.md5` files
- Verify file sizes match between source and destination
- Delete problematic cache files to force re-copy

### Clone taking too long

- Large drives with many files can take hours or days
- Progress is saved, safe to interrupt and resume
- Consider using `-SkipHashComparison` for faster copy (but no verification)
- Hash generation is the slowest phase for large files

## Best Practices

1. **Test first**: Always run with `-DryRun` first to preview operations
2. **Monitor logs**: Check logs during and after operation for any issues
3. **Verify results**: Review verification log to ensure all files matched
4. **Keep cache**: Don't delete `.integrity_cache` folders - they enable resume
5. **Safe interruption**: You can safely interrupt (Ctrl+C) and resume later
6. **Space buffer**: Ensure destination has more free space than total source size
7. **Physical drives**: Works best with physical drives, USB/network drives may be slower

## Related Tools

- **DriveBuilder**: Builds media drives from CSV manifests, uses same hash cache format
- **TheScrubber**: Organizes and deduplicates media files
- **MediaSorter**: Main orchestration tool for media library management
