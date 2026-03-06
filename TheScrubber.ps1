param(
    [Parameter(Mandatory=$false)]
    [string]$TargetDrive = "F:\",
    
    [Parameter(Mandatory=$false)]
    [switch]$ScanOnly = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false,
    
    [Parameter(Mandatory=$false)]
    [string]$CustomNoiseWordsFile = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$Interactive = $false
)

<#
.SYNOPSIS
    TheScrubber - Removes garbage words from media filenames and folder names
    
.DESCRIPTION
    Step 1: Scans the target drive and identifies "garbage" words in filenames (quality indicators, codecs, release info, etc.)
    Step 2: Renames files and folders to remove these garbage words, creating clean media filenames
    
.PARAMETER TargetDrive
    The drive or path to scan (default: F:\)
    
.PARAMETER ScanOnly
    Only scan and report garbage words found, don't rename anything
    
.PARAMETER DryRun
    Show what would be renamed without actually renaming
    
.PARAMETER CustomNoiseWordsFile
    Path to a text file with additional garbage words (one per line)
    
.PARAMETER Interactive
    Ask for confirmation before each rename operation
    
.EXAMPLE
    .\TheScrubber.ps1 -ScanOnly
    Scans F: drive and reports all garbage words found
    
.EXAMPLE
    .\TheScrubber.ps1 -DryRun
    Shows what would be renamed without making changes
    
.EXAMPLE
    .\TheScrubber.ps1 -TargetDrive "E:\" -Interactive
    Renames files on E: drive with confirmation prompts
#>

# Normalize the target path
$target = $TargetDrive.TrimEnd('\')
if ($target -match '^[A-Z]:$') {
    $target = $target + "\"
}

# Verify target exists
if (-not (Test-Path -LiteralPath $target)) {
    Write-Error "Target drive/path does not exist: $target"
    exit 1
}

# Create logs folder if it doesn't exist
$logsFolder = "logs"
if (-not (Test-Path $logsFolder)) {
    New-Item -ItemType Directory -Path $logsFolder | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$scanLog = Join-Path $logsFolder "scrubber_scan_${timestamp}.log"
$renameLog = Join-Path $logsFolder "scrubber_rename_${timestamp}.log"
$garbageWordsFile = Join-Path $logsFolder "garbage_words_found.txt"

# Base noise/garbage words list (from MediaSorter.ps1 and expanded)
$script:garbageWords = @(
    # Languages
    "GERMAN", "DUTCH", "FRENCH", "SPANISH", "ITALIAN", "JAPANESE", "RUSSIAN", "POLISH", "PORTUGUESE",
    "KOREAN", "CHINESE", "NORDIC", "SWEDISH", "NORWEGIAN", "FINNISH", "TURKISH",
    
    # Quality/Source
    "BluRay", "BDRip", "BRRip", "Remux", "WEB-DL", "WEBRip", "HDTV", "DVDRip", "WebHD",
    "HDCAM", "CAM", "TS", "TC", "DVDSCR", "SCREENER", "PDTV", "SDTV", "DSR",
    "HDRip", "PPVRip", "VHSRip", "VODRip", "AMZN", "NF", "DSNP", "HMAX", "ATVP",
    "iP", "WEB", "WEBRIP", "WEBDL",
    
    # Resolution
    "1080p", "720p", "2160p", "4K", "480p", "576p", "360p", "240p",
    "UHD", "FHD", "HD", "SD", "8K",
    
    # Video Codecs
    "x264", "x265", "h264", "h265", "HEVC", "AVC", "XviD", "DivX",
    "VP8", "VP9", "AV1", "MPEG2", "MPEG4",
    "10bit", "8bit", "10BIT", "8BIT",
    
    # Audio Codecs
    "AAC", "AC3", "DTS", "TrueHD", "Atmos", "EAC3", "DD5", "DDP5",
    "MP3", "FLAC", "DD51", "DTS-HD", "DTSHD", "MA", "DD", "DDP",
    "DD+", "E-AC-3",
    
    # Release Info
    "iNTERNAL", "PROPER", "REPACK", "LIMITED", "UNRATED", "EXTENDED", "DIRECTORS", "CUT",
    "COMPLETE", "FULL", "SEASON", "SERIES", "REMASTERED", "RETAIL", "RERIP",
    "UNCUT", "THEATRICAL", "DC", "SE", "LE",
    
    # Audio/Subtitle Options
    "MULTi", "DUAL", "SUBBED", "DUBBED", "DL", "SUBS", "MULTISUBS",
    
    # Release Groups Indicators (common patterns)
    "RARBG", "YIFY", "YTS", "PSA", "SPARKS", "CMRG", "ION10", "STUTTERSHIT",
    "FGT", "ETRG", "EVO", "DEFLATE", "INFLATE", "GECKOS", "HEVC",
    
    # Common Brackets/Delimiters patterns (these will be handled specially)
    # We'll remove content in brackets that matches patterns like [1080p] or (x265)
    
    # Misc
    "READNFO", "NFO", "INTERNAL", "CONVERT", "DUBBED"
)

# Convert all to lowercase for case-insensitive matching
$script:garbageWordsLower = $script:garbageWords | ForEach-Object { $_.ToLower() }

# Load custom noise words if provided
if ($CustomNoiseWordsFile -and (Test-Path -LiteralPath $CustomNoiseWordsFile)) {
    Write-Host "Loading custom garbage words from: $CustomNoiseWordsFile" -ForegroundColor Cyan
    $customWords = Get-Content -LiteralPath $CustomNoiseWordsFile | Where-Object { $_ -and $_.Trim() }
    $script:garbageWordsLower += $customWords | ForEach-Object { $_.Trim().ToLower() }
    $script:garbageWordsLower = $script:garbageWordsLower | Select-Object -Unique
}

# Statistics
$script:stats = @{
    TotalFiles = 0
    TotalFolders = 0
    FilesWithGarbage = 0
    FoldersWithGarbage = 0
    FilesRenamed = 0
    FoldersRenamed = 0
    Errors = 0
    GarbageWordsFound = @{}
}

function Write-Log {
    param([string]$Message, [string]$LogFile = $scanLog)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

function Extract-GarbageWords {
    param([string]$text)
    
    $foundWords = @()
    $textLower = $text.ToLower()
    
    # Check each known garbage word
    foreach ($garbageWord in $script:garbageWordsLower) {
        # Use word boundary matching to avoid false positives
        # Match as whole word with various delimiters
        if ($textLower -match "[\.\-_ \[\(\{]$([regex]::Escape($garbageWord))[\.\-_ \]\)\}]" -or
            $textLower -match "^$([regex]::Escape($garbageWord))[\.\-_ \]\)\}]" -or
            $textLower -match "[\.\-_ \[\(\{]$([regex]::Escape($garbageWord))$") {
            $foundWords += $garbageWord
            
            # Track frequency
            if (-not $script:stats.GarbageWordsFound.ContainsKey($garbageWord)) {
                $script:stats.GarbageWordsFound[$garbageWord] = 0
            }
            $script:stats.GarbageWordsFound[$garbageWord]++
        }
    }
    
    return $foundWords
}

function Clean-Name {
    param([string]$name)
    
    $cleaned = $name
    
    # Remove content in brackets/parens that contains garbage words or looks like technical info
    # Example: [1080p], (x265), {HEVC}, etc.
    $cleaned = $cleaned -replace '\[[^\]]*?(1080p|720p|2160p|4K|x264|x265|HEVC|BluRay|WEB-DL|AAC|DTS)[^\]]*?\]', ''
    $cleaned = $cleaned -replace '\([^\)]*?(1080p|720p|2160p|4K|x264|x265|HEVC|BluRay|WEB-DL|AAC|DTS)[^\)]*?\)', ''
    $cleaned = $cleaned -replace '\{[^\}]*?(1080p|720p|2160p|4K|x264|x265|HEVC|BluRay|WEB-DL|AAC|DTS)[^\}]*?\}', ''
    
    # Remove each garbage word (case-insensitive)
    foreach ($garbageWord in $script:garbageWords) {
        # Remove with various delimiters around it
        $pattern = [regex]::Escape($garbageWord)
        
        # Remove with dots, dashes, underscores, spaces
        $cleaned = $cleaned -replace "[\.\-_ ]$pattern[\.\-_ ]", ' '
        $cleaned = $cleaned -replace "^$pattern[\.\-_ ]", ''
        $cleaned = $cleaned -replace "[\.\-_ ]$pattern$", ''
        
        # Also remove when in brackets/parens (leftover cleanup)
        $cleaned = $cleaned -replace "\[$pattern\]", ''
        $cleaned = $cleaned -replace "\($pattern\)", ''
        $cleaned = $cleaned -replace "\{$pattern\}", ''
    }
    
    # Clean up multiple delimiters
    $cleaned = $cleaned -replace '[\.\-_]{2,}', '.'  # Multiple delimiters become single dot
    $cleaned = $cleaned -replace '\s{2,}', ' '        # Multiple spaces become single space
    $cleaned = $cleaned -replace '[\s\.\-_]+\.', '.'  # Clean up before dots
    $cleaned = $cleaned -replace '\.[\s\.\-_]+', '.'  # Clean up after dots
    
    # Remove empty brackets
    $cleaned = $cleaned -replace '\[\s*\]', ''
    $cleaned = $cleaned -replace '\(\s*\)', ''
    $cleaned = $cleaned -replace '\{\s*\}', ''
    
    # Trim spaces and delimiters from start/end
    $cleaned = $cleaned.Trim(' ', '.', '-', '_')
    
    # Final cleanup: remove trailing delimiters before extension
    $cleaned = $cleaned -replace '[\.\-_]+(\.[a-zA-Z0-9]{2,4})$', '$1'
    
    return $cleaned
}

function Scan-Items {
    param([string]$path)
    
    Write-Host "`nSTEP 1: Scanning $path for media files and folders..." -ForegroundColor Green
    Write-Host "This may take a while depending on the size of your drive...`n"
    
    $items = @{
        Files = @()
        Folders = @()
    }
    
    # Progress tracking
    $progressId = 1
    $scanStartTime = Get-Date
    
    try {
        # Get all items recursively
        Write-Progress -Id $progressId -Activity "Scanning drive" -Status "Enumerating items..." -PercentComplete 0
        
        # Get all directories first
        $allFolders = @(Get-ChildItem -LiteralPath $path -Directory -Recurse -ErrorAction SilentlyContinue)
        $script:stats.TotalFolders = $allFolders.Count
        
        Write-Host "Found $($allFolders.Count) folders to analyze" -ForegroundColor Cyan
        
        # Analyze folders for garbage words
        $folderCount = 0
        foreach ($folder in $allFolders) {
            $folderCount++
            if ($folderCount % 100 -eq 0 -or $folderCount -eq $allFolders.Count) {
                $percentComplete = [math]::Min(100, [int](($folderCount / $allFolders.Count) * 50))
                Write-Progress -Id $progressId -Activity "Analyzing folders" -Status "$folderCount / $($allFolders.Count)" -PercentComplete $percentComplete
            }
            
            $garbageWords = Extract-GarbageWords -text $folder.Name
            if ($garbageWords.Count -gt 0) {
                $script:stats.FoldersWithGarbage++
                $items.Folders += @{
                    Path = $folder.FullName
                    Name = $folder.Name
                    GarbageWords = $garbageWords
                }
            }
        }
        
        # Now get all files
        Write-Progress -Id $progressId -Activity "Scanning drive" -Status "Enumerating files..." -PercentComplete 50
        
        # Common video extensions
        $videoExtensions = @(".mkv", ".mp4", ".m4v", ".avi", ".mov", ".wmv", ".ts", ".m2ts", ".webm", ".flv", ".mpg", ".mpeg")
        
        $allFiles = @(Get-ChildItem -LiteralPath $path -File -Recurse -ErrorAction SilentlyContinue | 
                      Where-Object { $videoExtensions -contains $_.Extension.ToLower() })
        $script:stats.TotalFiles = $allFiles.Count
        
        Write-Host "Found $($allFiles.Count) video files to analyze" -ForegroundColor Cyan
        
        # Analyze files for garbage words
        $fileCount = 0
        foreach ($file in $allFiles) {
            $fileCount++
            if ($fileCount % 50 -eq 0 -or $fileCount -eq $allFiles.Count) {
                $percentComplete = [math]::Min(100, 50 + [int](($fileCount / $allFiles.Count) * 50))
                Write-Progress -Id $progressId -Activity "Analyzing files" -Status "$fileCount / $($allFiles.Count)" -PercentComplete $percentComplete
            }
            
            $nameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $garbageWords = Extract-GarbageWords -text $nameWithoutExt
            if ($garbageWords.Count -gt 0) {
                $script:stats.FilesWithGarbage++
                $items.Files += @{
                    Path = $file.FullName
                    Name = $file.Name
                    Directory = $file.DirectoryName
                    Extension = $file.Extension
                    GarbageWords = $garbageWords
                }
            }
        }
        
        Write-Progress -Id $progressId -Activity "Scanning complete" -Completed
        
    } catch {
        Write-Error "Error during scan: $_"
        Write-Log "SCAN ERROR: $_" -LogFile $scanLog
        $script:stats.Errors++
    }
    
    $scanDuration = (Get-Date) - $scanStartTime
    Write-Host "`nScan completed in $($scanDuration.TotalMinutes.ToString('0.00')) minutes" -ForegroundColor Green
    
    return $items
}

function Show-ScanResults {
    param($items)
    
    Write-Host "`n" ("="*80) -ForegroundColor Yellow
    Write-Host "SCAN RESULTS" -ForegroundColor Yellow
    Write-Host ("="*80) -ForegroundColor Yellow
    
    Write-Host "`nFolders:" -ForegroundColor Cyan
    Write-Host "  Total folders scanned:           $($script:stats.TotalFolders)"
    Write-Host "  Folders with garbage words:      $($script:stats.FoldersWithGarbage)" -ForegroundColor $(if($script:stats.FoldersWithGarbage -gt 0){"Red"}else{"Green"})
    
    Write-Host "`nFiles:" -ForegroundColor Cyan
    Write-Host "  Total video files scanned:       $($script:stats.TotalFiles)"
    Write-Host "  Files with garbage words:        $($script:stats.FilesWithGarbage)" -ForegroundColor $(if($script:stats.FilesWithGarbage -gt 0){"Red"}else{"Green"})
    
    Write-Host "`nGarbage Words Found (Top 20):" -ForegroundColor Cyan
    $topGarbage = $script:stats.GarbageWordsFound.GetEnumerator() | 
                  Sort-Object -Property Value -Descending | 
                  Select-Object -First 20
    
    foreach ($entry in $topGarbage) {
        Write-Host "  $($entry.Key.PadRight(20)) : $($entry.Value) occurrences" -ForegroundColor Gray
    }
    
    # Save full garbage words list to file
    if ($script:stats.GarbageWordsFound.Count -gt 0) {
        $script:stats.GarbageWordsFound.GetEnumerator() | 
            Sort-Object -Property Value -Descending | 
            ForEach-Object { "$($_.Key) : $($_.Value)" } | 
            Out-File -FilePath $garbageWordsFile -Encoding UTF8
        Write-Host "`nFull garbage words list saved to: $garbageWordsFile" -ForegroundColor Green
    }
    
    Write-Host "`n" ("="*80) -ForegroundColor Yellow
}

function Rename-Items {
    param($items)
    
    if ($items.Files.Count -eq 0 -and $items.Folders.Count -eq 0) {
        Write-Host "`nNo items need renaming. Drive is already clean!" -ForegroundColor Green
        return
    }
    
    Write-Host "`n" ("="*80) -ForegroundColor Yellow
    Write-Host "STEP 2: Cleaning up filenames" -ForegroundColor Green
    Write-Host ("="*80) -ForegroundColor Yellow
    
    if ($DryRun) {
        Write-Host "`n*** DRY RUN MODE - No actual changes will be made ***`n" -ForegroundColor Magenta
    }
    
    # Process folders first (from deepest to shallowest to avoid path issues)
    if ($items.Folders.Count -gt 0) {
        Write-Host "`nProcessing folders..." -ForegroundColor Cyan
        $sortedFolders = $items.Folders | Sort-Object { $_.Path.Length } -Descending
        
        $folderNum = 0
        foreach ($folderInfo in $sortedFolders) {
            $folderNum++
            $oldPath = $folderInfo.Path
            $parentPath = Split-Path -Path $oldPath -Parent
            $oldName = $folderInfo.Name
            $newName = Clean-Name -name $oldName
            
            if ($newName -eq $oldName) {
                continue  # No change needed
            }
            
            $newPath = Join-Path $parentPath $newName
            
            Write-Host "[$folderNum/$($sortedFolders.Count)] " -NoNewline -ForegroundColor Gray
            Write-Host "Folder: " -NoNewline -ForegroundColor Yellow
            Write-Host "$oldName" -ForegroundColor White
            Write-Host "    -> " -NoNewline -ForegroundColor DarkGray
            Write-Host "$newName" -ForegroundColor Green
            
            Write-Log "FOLDER RENAME: '$oldPath' -> '$newPath'" -LogFile $renameLog
            
            if ($Interactive) {
                $response = Read-Host "Rename this folder? (Y/N)"
                if ($response -ne 'Y' -and $response -ne 'y') {
                    Write-Host "    Skipped by user" -ForegroundColor DarkGray
                    continue
                }
            }
            
            if (-not $DryRun) {
                try {
                    # Check if target already exists
                    if (Test-Path -LiteralPath $newPath) {
                        Write-Host "    ERROR: Target already exists: $newPath" -ForegroundColor Red
                        Write-Log "ERROR: Target exists: '$newPath'" -LogFile $renameLog
                        $script:stats.Errors++
                        continue
                    }
                    
                    Rename-Item -LiteralPath $oldPath -NewName $newName -ErrorAction Stop
                    $script:stats.FoldersRenamed++
                } catch {
                    Write-Host "    ERROR: $_" -ForegroundColor Red
                    Write-Log "ERROR renaming folder '$oldPath': $_" -LogFile $renameLog
                    $script:stats.Errors++
                }
            } else {
                $script:stats.FoldersRenamed++
            }
        }
    }
    
    # Process files
    if ($items.Files.Count -gt 0) {
        Write-Host "`nProcessing files..." -ForegroundColor Cyan
        
        $fileNum = 0
        foreach ($fileInfo in $items.Files) {
            $fileNum++
            $oldPath = $fileInfo.Path
            $directory = $fileInfo.Directory
            $oldName = $fileInfo.Name
            $extension = $fileInfo.Extension
            
            $nameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($oldName)
            $cleanedName = Clean-Name -name $nameWithoutExt
            $newName = $cleanedName + $extension
            
            if ($newName -eq $oldName) {
                continue  # No change needed
            }
            
            $newPath = Join-Path $directory $newName
            
            Write-Host "[$fileNum/$($items.Files.Count)] " -NoNewline -ForegroundColor Gray
            Write-Host "$oldName" -ForegroundColor White
            Write-Host "    -> " -NoNewline -ForegroundColor DarkGray
            Write-Host "$newName" -ForegroundColor Green
            
            Write-Log "FILE RENAME: '$oldPath' -> '$newPath'" -LogFile $renameLog
            
            if ($Interactive) {
                $response = Read-Host "Rename this file? (Y/N)"
                if ($response -ne 'Y' -and $response -ne 'y') {
                    Write-Host "    Skipped by user" -ForegroundColor DarkGray
                    continue
                }
            }
            
            if (-not $DryRun) {
                try {
                    # Check if target already exists
                    if (Test-Path -LiteralPath $newPath) {
                        Write-Host "    ERROR: Target already exists: $newPath" -ForegroundColor Red
                        Write-Log "ERROR: Target exists: '$newPath'" -LogFile $renameLog
                        $script:stats.Errors++
                        continue
                    }
                    
                    Rename-Item -LiteralPath $oldPath -NewName $newName -ErrorAction Stop
                    $script:stats.FilesRenamed++
                } catch {
                    Write-Host "    ERROR: $_" -ForegroundColor Red
                    Write-Log "ERROR renaming file '$oldPath': $_" -LogFile $renameLog
                    $script:stats.Errors++
                }
            } else {
                $script:stats.FilesRenamed++
            }
        }
    }
}

function Show-FinalResults {
    Write-Host "`n" ("="*80) -ForegroundColor Yellow
    Write-Host "FINAL RESULTS" -ForegroundColor Yellow
    Write-Host ("="*80) -ForegroundColor Yellow
    
    if ($ScanOnly) {
        Write-Host "`nScan-only mode - no items were renamed" -ForegroundColor Cyan
    } elseif ($DryRun) {
        Write-Host "`nDry-run mode - showing what WOULD be renamed:" -ForegroundColor Magenta
    } else {
        Write-Host "`nRename operations completed:" -ForegroundColor Green
    }
    
    Write-Host "  Folders renamed:    $($script:stats.FoldersRenamed) / $($script:stats.FoldersWithGarbage)"
    Write-Host "  Files renamed:      $($script:stats.FilesRenamed) / $($script:stats.FilesWithGarbage)"
    if ($script:stats.Errors -gt 0) {
        Write-Host "  Errors:             $($script:stats.Errors)" -ForegroundColor Red
    }
    
    Write-Host "`nLogs saved to:"
    Write-Host "  Scan log:      $scanLog" -ForegroundColor Gray
    if (-not $ScanOnly) {
        Write-Host "  Rename log:    $renameLog" -ForegroundColor Gray
    }
    
    Write-Host "`n" ("="*80) -ForegroundColor Yellow
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Host "`n"
Write-Host ("="*80) -ForegroundColor Cyan
Write-Host "                              THE SCRUBBER" -ForegroundColor Cyan
Write-Host "           Media Filename Cleanup Utility - Removes Garbage Words" -ForegroundColor Cyan
Write-Host ("="*80) -ForegroundColor Cyan

Write-Host "`nTarget Drive: $target" -ForegroundColor White
Write-Host "Mode: " -NoNewline
if ($ScanOnly) {
    Write-Host "SCAN ONLY" -ForegroundColor Yellow
} elseif ($DryRun) {
    Write-Host "DRY RUN" -ForegroundColor Magenta
} else {
    Write-Host "FULL RENAME" -ForegroundColor Green
}

Write-Host "Garbage words loaded: $($script:garbageWordsLower.Count)" -ForegroundColor Cyan

if (-not $ScanOnly -and -not $DryRun) {
    Write-Host "`nWARNING: This will rename files and folders on $target" -ForegroundColor Red
    $confirm = Read-Host "Are you sure you want to proceed? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "Operation cancelled by user" -ForegroundColor Yellow
        exit 0
    }
}

# STEP 1: Scan the drive
$items = Scan-Items -path $target

# Show scan results
Show-ScanResults -items $items

# STEP 2: Rename items (unless scan-only mode)
if (-not $ScanOnly) {
    Rename-Items -items $items
}

# Show final results
Show-FinalResults

Write-Host "`nTheScrubber completed successfully!`n" -ForegroundColor Green
