param(
    [Parameter(Mandatory=$true)]
    [string]$DestinationDrive,
    
    [Parameter(Mandatory=$false)]
    [string[]]$SourceCsvPatterns = @("*_media_items.csv"),
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false,

    [Parameter(Mandatory=$false)]
    [switch]$ExcludeClips = $false,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('None', 'Quick', 'True')]
    [string]$IntegrityMode = 'None'
)

# Normalize the destination path
$dest = $DestinationDrive.TrimEnd('\')
if ($dest -match '^[A-Z]:$') {
    $dest = $dest + "\"
}

# Verify destination exists
if (-not (Test-Path -LiteralPath $dest)) {
    Write-Error "Destination drive/path does not exist: $dest"
    exit 1
}

# Verify destination is writable and properly accessible
$testFile = Join-Path $dest ".drive_builder_test_$([guid]::NewGuid().ToString().Substring(0,8))"
try {
    # Try to create a test file to verify write access and format
    $null = New-Item -ItemType File -Path $testFile -Force -ErrorAction Stop
    Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
}
catch {
    Write-Error "Destination drive appears to be formatted incorrectly or is not writable: $dest"
    Write-Error "Error details: $_"
    Write-Error ""
    Write-Error "Possible causes:"
    Write-Error "  - Drive is formatted with incompatible filesystem (some drives need FAT32, NTFS, or exFAT)"
    Write-Error "  - Drive is read-only or mounted as read-only"
    Write-Error "  - Missing write permissions to the drive"
    Write-Error "  - Drive is corrupted or not properly initialized"
    exit 1
}

# Archive extensions that need to be extracted
$tarExtensions = @(".tar", ".tgz", ".tar.gz", ".tar.xz", ".tar.zst")
$partialCopySuffix = ".__partial_copy__"
$partialExtractSuffix = ".__partial_extract__"
$archiveCompletionMarkerFile = ".drive_builder_extract_complete"
$integrityCacheFolder = ".integrity_cache"
$integrityProgressId = 2

# Define category mappings
$categoryFolderMap = @{
    "TV_Episode"   = "TV"
    "TV_Season"    = "TV"
    "TV"           = "TV"
    "Movie"        = "Movies"
    "Clip"         = "Clips"
}

# Categories intentionally excluded from export.
$excludedAutoCategories = @("personal", "unknown")
if ($ExcludeClips) {
    $excludedAutoCategories += "clip"
}
$excludedCategorySummary = $excludedAutoCategories -join ", "

# Logging
$logsFolder = "logs"
if (-not (Test-Path -LiteralPath $logsFolder)) {
    New-Item -ItemType Directory -Path $logsFolder | Out-Null
}
$driveBuilderLog = Join-Path $logsFolder "drive_builder.log"
$errorLog = Join-Path $logsFolder "drive_builder_errors.log"

$logEntries = New-Object System.Collections.Generic.List[String]
$errorEntries = New-Object System.Collections.Generic.List[String]

function Write-LogsToDisk {
    try {
        if ($logEntries.Count -gt 0) {
            $logEntries | Out-File -FilePath $driveBuilderLog -Encoding UTF8
        }
    }
    catch {
        # If logging fails, still continue script flow so the original error is visible.
    }

    try {
        if ($errorEntries.Count -gt 0) {
            $errorEntries | Out-File -FilePath $errorLog -Encoding UTF8
        }
    }
    catch {
        # If logging fails, still continue script flow so the original error is visible.
    }
}

function Log-Message {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] $Message"
    $logEntries.Add($entry)
    Write-Host $entry
}

function Log-Error {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] ERROR: $Message"
    $errorEntries.Add($entry)
    Write-Host $entry -ForegroundColor Red
    Write-LogsToDisk
}

function Stop-DriveBuilder {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [int]$ExitCode = 1
    )

    Log-Error $Message

    try {
        Write-Progress -Activity "Copying files to drive" -Completed
        Write-Progress -Id $integrityProgressId -Activity "Verifying file integrity (MD5)" -Completed
    }
    catch {
        # Best-effort cleanup of progress UI.
    }

    Log-Message "=== Drive Builder Aborted ==="
    Log-Message "Log file: $driveBuilderLog"
    if ($errorEntries.Count -gt 0) {
        Log-Message "Error log: $errorLog"
    }

    Write-LogsToDisk
    exit $ExitCode
}

function Get-TruncatedText {
    param(
        [string]$Text,
        [int]$MaxLength = 80
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }

    if ($MaxLength -le 0) {
        return ""
    }

    if ($Text.Length -le $MaxLength) {
        return $Text
    }

    if ($MaxLength -le 3) {
        return $Text.Substring(0, $MaxLength)
    }

    return $Text.Substring(0, $MaxLength - 3) + "..."
}

function Get-ProgressViewportWidth {
    param([int]$Fallback = 120)

    try {
        $width = [int]$Host.UI.RawUI.WindowSize.Width
        if ($width -ge 40) {
            return $width
        }
    }
    catch {
        # Non-interactive host; fall back to conservative width.
    }

    return $Fallback
}

function Write-IntegrityProgress {
    param(
        [string]$Status,
        [string]$CurrentOperation,
        [double]$PercentComplete
    )

    $viewportWidth = Get-ProgressViewportWidth
    $statusMaxLength = [math]::Min(44, [math]::Max(24, [int][math]::Floor($viewportWidth * 0.55)))
    $operationMaxLength = [math]::Min(64, [math]::Max(24, [int][math]::Floor($viewportWidth * 0.75)))
    $safePercent = [int][math]::Min(100, [math]::Max(0, [math]::Round($PercentComplete)))

    Write-Progress -Id $integrityProgressId `
        -Activity "Verifying file integrity (MD5)" `
        -Status (Get-TruncatedText -Text $Status -MaxLength $statusMaxLength) `
        -PercentComplete $safePercent `
        -CurrentOperation (Get-TruncatedText -Text $CurrentOperation -MaxLength $operationMaxLength)
}

function Get-HashCachePath {
    param(
        [string]$DestinationFile,
        [string]$DestinationBasePath
    )
    
    # Get relative path from destination base to file
    $fileName = Split-Path $DestinationFile -Leaf
    $parentPath = Split-Path $DestinationFile -Parent
    
    # Build cache folder path
    $cacheRoot = Join-Path $DestinationBasePath $integrityCacheFolder
    
    # If file is in a subfolder, maintain structure in cache
    if ($parentPath -ne $DestinationBasePath) {
        $relativePath = $parentPath.Substring($DestinationBasePath.Length).TrimStart('\')
        $cacheFolderPath = Join-Path $cacheRoot $relativePath
    } else {
        $cacheFolderPath = $cacheRoot
    }
    
    $hashFileName = $fileName + ".md5"
    return @{
        CacheFolder = $cacheFolderPath
        HashFile = Join-Path $cacheFolderPath $hashFileName
    }
}

function Save-HashToCache {
    param(
        [string]$DestinationFile,
        [string]$DestinationBasePath,
        [string]$Hash,
        [long]$FileSize
    )
    
    try {
        $cachePaths = Get-HashCachePath -DestinationFile $DestinationFile -DestinationBasePath $DestinationBasePath
        
        # Ensure cache folder exists
        if (-not (Test-Path -LiteralPath $cachePaths.CacheFolder)) {
            New-Item -ItemType Directory -Path $cachePaths.CacheFolder -Force -ErrorAction Stop | Out-Null
        }
        
        # Write hash file with metadata
        # Use -LiteralPath for Out-File to avoid wildcard expansion of brackets
        $cacheData = @{
            Hash = $Hash
            FileSize = $FileSize
            Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            FileName = (Split-Path $DestinationFile -Leaf)
        }
        
        $cacheContent = "$($cacheData.Hash)`n$($cacheData.FileSize)`n$($cacheData.Timestamp)`n$($cacheData.FileName)"
        $cacheContent | Out-File -LiteralPath $cachePaths.HashFile -Encoding ASCII -Force
        
        return $true
    }
    catch {
        Log-Error "Failed to save hash to cache: $_"
        return $false
    }
}

function Get-HashFromCache {
    param(
        [string]$DestinationFile,
        [string]$DestinationBasePath,
        [long]$ExpectedFileSize = -1
    )
    
    try {
        $cachePaths = Get-HashCachePath -DestinationFile $DestinationFile -DestinationBasePath $DestinationBasePath
        
        if (-not (Test-Path -LiteralPath $cachePaths.HashFile -PathType Leaf)) {
            return $null
        }
        
        # Read and validate cache file
        $lines = Get-Content -LiteralPath $cachePaths.HashFile -ErrorAction Stop
        
        if ($lines.Count -lt 2) {
            # Invalid cache format
            return $null
        }
        
        $hash = $lines[0].Trim()
        $cachedSize = [long]$lines[1].Trim()
        
        # Validate hash format (32 hex characters for MD5)
        if ($hash -notmatch '^[a-fA-F0-9]{32}$') {
            return $null
        }
        
        # Verify file size matches if provided
        if ($ExpectedFileSize -ge 0 -and $cachedSize -ne $ExpectedFileSize) {
            return $null
        }
        
        return @{
            Hash = $hash.ToLower()
            FileSize = $cachedSize
            IsValid = $true
        }
    }
    catch {
        return $null
    }
}

function Remove-HashFromCache {
    param(
        [string]$DestinationFile,
        [string]$DestinationBasePath
    )
    
    try {
        $cachePaths = Get-HashCachePath -DestinationFile $DestinationFile -DestinationBasePath $DestinationBasePath
        
        if (Test-Path -LiteralPath $cachePaths.HashFile -PathType Leaf) {
            Remove-Item -LiteralPath $cachePaths.HashFile -Force -ErrorAction Stop
        }
        
        return $true
    }
    catch {
        Log-Error "Failed to remove hash from cache: $_"
        return $false
    }
}



function Get-FileMD5 {
    param(
        [string]$FilePath,
        [int]$TimeoutSeconds = 300,
        [scriptblock]$ProgressCallback = $null
    )
    
    $hashString = $null
    $stream = $null
    $md5 = $null
    
    try {
        $file = Get-Item -LiteralPath $FilePath -ErrorAction Stop
        $fileSize = [long]$file.Length
        $bytesReadTotal = 0L

        $md5 = [System.Security.Cryptography.MD5]::Create()
        $stream = $file.OpenRead()

        $bufferSize = 4MB
        $buffer = New-Object byte[] $bufferSize
        $updateIntervalMs = 200
        $progressTimer = [System.Diagnostics.Stopwatch]::StartNew()

        while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $null = $md5.TransformBlock($buffer, 0, $bytesRead, $null, 0)
            $bytesReadTotal += $bytesRead

            if ($ProgressCallback -and ($progressTimer.ElapsedMilliseconds -ge $updateIntervalMs -or $bytesReadTotal -eq $fileSize)) {
                try {
                    & $ProgressCallback $bytesReadTotal $fileSize
                }
                catch {
                    # Progress UI failures should not break hashing.
                }
                $progressTimer.Restart()
            }
        }

        $null = $md5.TransformFinalBlock(([byte[]]::new(0)), 0, 0)

        if ($ProgressCallback) {
            try {
                & $ProgressCallback $fileSize $fileSize
            }
            catch {
                # Progress UI failures should not break hashing.
            }
        }

        $hashString = [System.BitConverter]::ToString($md5.Hash).Replace("-", "").ToLower()
    }
    catch {
        Log-Error "Failed to compute MD5 for $FilePath : $_"
        $hashString = $null
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
        if ($md5) {
            $md5.Dispose()
        }
    }
    
    return $hashString
}

function Compare-FileIntegrity {
    param(
        [string]$SourceFile,
        [string]$DestinationFile,
        [int]$CurrentItem = 0,
        [int]$TotalItems = 0,
        [long]$ProcessedBytes = 0,
        [long]$TotalBytes = 0
    )
    
    try {
        if (-not (Test-Path -LiteralPath $SourceFile) -or -not (Test-Path -LiteralPath $DestinationFile)) {
            return @{ IntegrityOk = $false; Reason = "Source or destination file missing" }
        }
        
        $fileName = Split-Path $SourceFile -Leaf
        $displayName = Get-TruncatedText -Text $fileName -MaxLength 32
        $itemLabel = if ($CurrentItem -gt 0 -and $TotalItems -gt 0) {
            "Item $CurrentItem/$TotalItems"
        } else {
            "Integrity check"
        }

        Write-IntegrityProgress `
            -Status "$itemLabel | Src hash 0%" `
            -CurrentOperation "$displayName | preparing src hash" `
            -PercentComplete 0

        $sourceMD5 = Get-FileMD5 -FilePath $SourceFile -ProgressCallback {
            param([long]$BytesRead, [long]$FileSize)

            $filePercent = if ($FileSize -gt 0) {
                [math]::Min(100, [math]::Round(($BytesRead / $FileSize) * 100, 2))
            } else {
                100
            }
            $overallPercent = [math]::Round($filePercent / 2, 2)

            Write-IntegrityProgress `
                -Status "$itemLabel | Src hash $filePercent%" `
                -CurrentOperation "$displayName | src $([math]::Round($BytesRead / 1GB, 2))/$([math]::Round($FileSize / 1GB, 2)) GB" `
                -PercentComplete $overallPercent
        }
        if ($null -eq $sourceMD5) {
            return @{ IntegrityOk = $false; Reason = "Failed to compute source MD5" }
        }
        
        Write-IntegrityProgress `
            -Status "$itemLabel | Dst hash 0%" `
            -CurrentOperation "$displayName | preparing dst hash" `
            -PercentComplete 50

        $destMD5 = Get-FileMD5 -FilePath $DestinationFile -ProgressCallback {
            param([long]$BytesRead, [long]$FileSize)

            $filePercent = if ($FileSize -gt 0) {
                [math]::Min(100, [math]::Round(($BytesRead / $FileSize) * 100, 2))
            } else {
                100
            }
            $overallPercent = [math]::Round(50 + ($filePercent / 2), 2)

            Write-IntegrityProgress `
                -Status "$itemLabel | Dst hash $filePercent%" `
                -CurrentOperation "$displayName | dst $([math]::Round($BytesRead / 1GB, 2))/$([math]::Round($FileSize / 1GB, 2)) GB" `
                -PercentComplete $overallPercent
        }
        if ($null -eq $destMD5) {
            return @{ IntegrityOk = $false; Reason = "Failed to compute destination MD5" }
        }
        
        $match = $sourceMD5 -eq $destMD5
        $reason = if ($match) { "OK" } else { "CORRUPTION DETECTED: Hash mismatch" }

        Write-IntegrityProgress `
            -Status "$itemLabel | Hash compare complete" `
            -CurrentOperation "$displayName | hashes compared" `
            -PercentComplete 100
        
        # Only log and display if there's corruption
        if (-not $match) {
            Write-Host ""  # New line to separate from other output
            Write-Host "⚠️  CORRUPTION DETECTED: $fileName" -ForegroundColor Red
            Log-Error "File corruption detected: $fileName"
            Log-Error "  Source MD5:      $sourceMD5"
            Log-Error "  Destination MD5: $destMD5"
        }
        
        return @{
            IntegrityOk = $match
            Reason = $reason
            SourceMD5 = $sourceMD5
            DestinationMD5 = $destMD5
        }
    }
    catch {
        return @{ IntegrityOk = $false; Reason = "Integrity check error: $_" }
    }
}

function Get-ArchiveExtractFolderName {
    param(
        [string]$FileName
    )

    $name = [System.IO.Path]::GetFileName($FileName)
    $lower = $name.ToLower()

    foreach ($suffix in @('.tar.gz', '.tar.xz', '.tar.zst', '.tgz', '.tar')) {
        if ($lower.EndsWith($suffix)) {
            return $name.Substring(0, $name.Length - $suffix.Length)
        }
    }

    return [System.IO.Path]::GetFileNameWithoutExtension($name)
}

function Get-IsArchiveFile {
    param(
        [string]$FileName
    )

    $ext = [System.IO.Path]::GetExtension($FileName).ToLower()
    return ($tarExtensions -contains $ext -or ($FileName -match "\.tar\.(gz|xz|zst)$"))
}

function Get-ArchiveTransferPaths {
    param(
        [string]$DestinationPath,
        [string]$FileName
    )

    $extractFolderName = Get-ArchiveExtractFolderName -FileName $FileName
    $extractPath = Join-Path $DestinationPath $extractFolderName

    return [PSCustomObject]@{
        ExtractFolderName   = $extractFolderName
        ExtractPath         = $extractPath
        PartialExtractPath  = $extractPath + $partialExtractSuffix
        CompletionMarker    = Join-Path $extractPath $archiveCompletionMarkerFile
    }
}

function Test-IsExcludedCategory {
    param(
        [string]$AutoCategory
    )

    if ([string]::IsNullOrWhiteSpace($AutoCategory)) {
        return $false
    }

    return $excludedAutoCategories -contains $AutoCategory.Trim().ToLower()
}

function Get-DetermineFolderName {
    param(
        [string]$AutoCategory,
        [string]$ShowName,
        [string]$FileName
    )
    
    # Determine the main category folder
    $categoryFolder = $categoryFolderMap[$AutoCategory]
    if (-not $categoryFolder) {
        $categoryFolder = "Clips"
    }
    
    # For TV shows, create Show/Season structure
    if ($categoryFolder -eq "TV" -and $ShowName) {
        $tvRoot = Join-Path $dest "TV"
        return @{
            Category = $categoryFolder
            SubFolder = $ShowName
            FullPath = Join-Path $tvRoot $ShowName
        }
    }
    
    return @{
        Category = $categoryFolder
        SubFolder = ""
        FullPath = Join-Path $dest $categoryFolder
    }
}

function Extract-TarArchivePerFile {
    param(
        [string]$ArchivePath,
        [string]$DestinationPath
    )
    
    try {
        # Ensure destination exists
        if (-not (Test-Path -LiteralPath $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction Stop | Out-Null
        }
        
        $archiveName = Split-Path $ArchivePath -Leaf
        Log-Message "Attempting extract-all without excluding, to skip corrupted files..."
        
        # With corrupted archives, tar --ignore-command-error might help if available
        # Otherwise just try to extract everything and collect what works
        $tempStderr = [System.IO.Path]::GetTempFileName()
        
        try {
            # Try extraction with error ignoring if available
            tar -xf "$ArchivePath" -C "$DestinationPath" --ignore-command-error 2>$tempStderr
            $extractExitCode = $LASTEXITCODE
            
            # Even if there are errors, some files may have been extracted
            if ($extractExitCode -ne 0) {
                Log-Message "Extraction completed with errors (exit code $extractExitCode), some files were extracted"
            }
            
            # Check what errors occurred
            $errors = Get-Content -LiteralPath $tempStderr -ErrorAction SilentlyContinue
            $skippedFiles = @()
            
            if ($errors) {
                foreach ($line in @($errors)) {
                    if ($line -match 'Truncated' -or $line -match 'error') {
                        Log-Message "  Note: $line"
                        # Try to extract filename if possible
                        if ($line -match '([^\s:][^:]*\.(mkv|mp4))') {
                            $skippedFiles += $matches[1]
                        }
                    }
                }
            }
            
            # Check if any files were extracted by looking at destination
            $extractedItems = Get-ChildItem -LiteralPath $DestinationPath -Recurse -ErrorAction SilentlyContinue | Measure-Object
            if ($extractedItems.Count -gt 0) {
                Log-Message "Successfully extracted files to destination (some files may have been skipped)"
                return @{
                    Success = $true
                    ExcludedFiles = $skippedFiles
                }
            } else {
                Log-Message "No files could be extracted from archive"
                return @{
                    Success = $false
                    ExcludedFiles = @()
                }
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempStderr) {
                Remove-Item -LiteralPath $tempStderr -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Log-Error "Failed to perform per-file extraction: $_"
        return @{
            Success = $false
            ExcludedFiles = @()
        }
    }
}

function Extract-TarArchive {
    param(
        [string]$ArchivePath,
        [string]$DestinationPath,
        [string[]]$ExcludePatterns = @()
    )
    
    try {
        # Ensure destination exists
        if (-not (Test-Path -LiteralPath $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction Stop | Out-Null
        }
        
        $archiveName = Split-Path $ArchivePath -Leaf
        $ext = [System.IO.Path]::GetExtension($archiveName).ToLower()
        $extractExitCode = 0
        $excludedFiles = @()
        
        # Determine if it needs decompression
        if ($ext -eq ".tgz" -or $archiveName -match "\.tar\.gz$" -or $archiveName -match "\.tar\.xz$" -or $archiveName -match "\.tar\.zst$") {
            Log-Message "Extracting (compressed): $archiveName to $DestinationPath"
            # Use 7z if available, otherwise use tar with appropriate decompression
            $7zPath = "C:\Program Files\7-Zip\7z.exe"
            if (Test-Path -LiteralPath $7zPath) {
                & $7zPath x "$ArchivePath" -o"$DestinationPath" -y | Out-Null
                $extractExitCode = $LASTEXITCODE
            } else {
                tar -xf "$ArchivePath" -C "$DestinationPath"
                $extractExitCode = $LASTEXITCODE
            }
        } else {
            Log-Message "Extracting (uncompressed): $archiveName to $DestinationPath"
            
            # Try initial extraction to temp file to capture stderr properly
            $tempStderr = [System.IO.Path]::GetTempFileName()
            try {
                tar -xf "$ArchivePath" -C "$DestinationPath" 2>$tempStderr
                $extractExitCode = $LASTEXITCODE
                
                # If extraction failed, check for specific corrupted file in error output
                if ($extractExitCode -ne 0) {
                    Log-Message "First extraction attempt failed with exit code $extractExitCode. Checking for corrupted file..."
                    
                    $errors = Get-Content -LiteralPath $tempStderr -ErrorAction SilentlyContinue
                    
                    # Look for truncation error with filename - format: "filename: Truncated tar archive"
                    if ($errors) {
                        $errorLines = @($errors) # Ensure it's an array
                        foreach ($line in $errorLines) {
                            # Match lines with "Truncated" to find corrupted files
                            # Format can be: "filename: Truncated tar archive..." or "tar : filename: Truncated..."
                            if ($line -match 'Truncated') {
                                # Try pattern 1: filename at start
                                if ($line -match '^([^:]+):\s+Truncated') {
                                    $badFile = $matches[1].Trim()
                                }
                                # Try pattern 2: "tar : filename : Truncated"
                                elseif ($line -match 'tar\s*:\s+([^:]+):\s+Truncated') {
                                    $badFile = $matches[1].Trim()
                                }
                                # Try pattern 3: Just extract anything before first colon with Truncated after
                                elseif ($line -match '([^\s:][^:]*\.mkv|[^:]*\.mp4).*Truncated') {
                                    $badFile = $matches[1].Trim()
                                }
                                
                                if ($badFile -and $badFile -notin $excludedFiles) {
                                    $excludedFiles += $badFile
                                    Log-Message "Detected corrupted file: $badFile"
                                }
                            }
                        }
                    }
                    
                    # If we found a bad file, retry with it excluded
                    if ($excludedFiles.Count -gt 0) {
                        Log-Message "Retrying extraction excluding $($excludedFiles.Count) corrupted file(s)..."
                        
                        $tarArgs = @("-xf", "$ArchivePath", "-C", "$DestinationPath")
                        foreach ($badFile in $excludedFiles) {
                            $tarArgs += @("--exclude", $badFile)
                        }
                        
                        # Clear stderr file for retry
                        Clear-Content -LiteralPath $tempStderr -Force
                        
                        tar @tarArgs 2>$tempStderr
                        $extractExitCode = $LASTEXITCODE
                        
                        if ($extractExitCode -eq 0) {
                            Log-Message "Partial extraction succeeded! Excluded corrupted file(s): $($excludedFiles -join ', ')"
                        } else {
                            # Log the retry error for debugging
                            $retryErrors = Get-Content -LiteralPath $tempStderr -ErrorAction SilentlyContinue
                            if ($retryErrors) {
                                Log-Message "Retry extraction failed. Stderr output:"
                                foreach ($line in @($retryErrors)) {
                                    if ($line.Trim()) {
                                        Log-Message "  $line"
                                    }
                                }
                            }
                            Log-Message "Attempted exclusion failed, trying per-file extraction..."
                            
                            # Try to extract files one at a time to skip bad ones
                            $fileExtractionResult = Extract-TarArchivePerFile -ArchivePath $ArchivePath -DestinationPath $DestinationPath
                            return $fileExtractionResult
                        }
                    } elseif ($extractExitCode -eq -1) {
                        # Exit code -1 usually means tar crashed/fatal error
                        Log-Message "CRITICAL: Archive extraction crashed (exit code -1)"
                        Log-Message "Attempting per-file extraction to skip corrupted files..."
                        
                        # Try to extract files one at a time to skip bad ones
                        $fileExtractionResult = Extract-TarArchivePerFile -ArchivePath $ArchivePath -DestinationPath $DestinationPath
                        return $fileExtractionResult
                    } else {
                        # Other exit code, log and skip
                        $retryErrors = Get-Content -LiteralPath $tempStderr -ErrorAction SilentlyContinue
                        if ($retryErrors) {
                            Log-Message "Extraction error details:"
                            foreach ($line in @($retryErrors)) {
                                if ($line.Trim()) {
                                    Log-Message "  $line"
                                }
                            }
                        }
                        Log-Message "Attempting per-file extraction to skip corrupted files..."
                        
                        # Try to extract files one at a time to skip bad ones
                        $fileExtractionResult = Extract-TarArchivePerFile -ArchivePath $ArchivePath -DestinationPath $DestinationPath
                        return $fileExtractionResult
                    }
                }
            }
            finally {
                if (Test-Path -LiteralPath $tempStderr) {
                    Remove-Item -LiteralPath $tempStderr -Force -ErrorAction SilentlyContinue
                }
            }
        }

        if ($extractExitCode -ne 0) {
            Log-Message "Archive extraction returned exit code $extractExitCode"
            return @{
                Success = $false
                ExcludedFiles = $excludedFiles
            }
        }
        
        return @{
            Success = $true
            ExcludedFiles = $excludedFiles
        }
    }
    catch {
        Log-Error "Failed to extract $ArchivePath : $_"
        return @{
            Success = $false
            ExcludedFiles = @()
        }
    }
}

function Get-TransferState {
    param(
        [string]$SourceFile,
        [string]$DestinationPath,
        [string]$IntegrityMode = 'None',
        [int]$CurrentItem = 0,
        [int]$TotalItems = 0
    )

    $fileName = Split-Path $SourceFile -Leaf
    $isArchive = Get-IsArchiveFile -FileName $fileName
    $sourceItem = Get-Item -LiteralPath $SourceFile -ErrorAction SilentlyContinue
    $sourceSize = if ($sourceItem) { [long]$sourceItem.Length } else { -1L }

    if ($isArchive) {
        $archivePaths = Get-ArchiveTransferPaths -DestinationPath $DestinationPath -FileName $fileName
        $hasExtractPath = Test-Path -LiteralPath $archivePaths.ExtractPath -PathType Container
        $hasPartialExtractPath = Test-Path -LiteralPath $archivePaths.PartialExtractPath -PathType Container
        $hasCompletionMarker = Test-Path -LiteralPath $archivePaths.CompletionMarker -PathType Leaf

        $isComplete = $hasExtractPath -and $hasCompletionMarker -and (-not $hasPartialExtractPath)
        $needsRepair = $hasPartialExtractPath -or ($hasExtractPath -and (-not $hasCompletionMarker))

        $reason = ""
        if ($hasPartialExtractPath) {
            $reason = "Partial archive extraction folder exists"
        } elseif ($hasExtractPath -and (-not $hasCompletionMarker)) {
            $reason = "Archive extraction folder exists without completion marker"
        }

        return [PSCustomObject]@{
            FileName               = $fileName
            IsArchive              = $true
            IsComplete             = $isComplete
            NeedsRepair            = $needsRepair
            Reason                 = $reason
            SourceSize             = $sourceSize
            SourceFile             = $SourceFile
            DestinationPath        = $DestinationPath
            DestinationFile        = $null
            PartialCopyFile        = $null
            HasFinalFile           = $false
            HasPartialFile         = $false
            DestinationSize        = -1L
            ExtractPath            = $archivePaths.ExtractPath
            PartialExtractPath     = $archivePaths.PartialExtractPath
            CompletionMarker       = $archivePaths.CompletionMarker
            HasExtractPath         = $hasExtractPath
            HasPartialExtractPath  = $hasPartialExtractPath
            HasCompletionMarker    = $hasCompletionMarker
            IntegrityOk            = $null
            IntegrityReason        = ""
        }
    }

    $destinationFile = Join-Path $DestinationPath $fileName
    $partialCopyFile = $destinationFile + $partialCopySuffix
    $hasFinalFile = Test-Path -LiteralPath $destinationFile -PathType Leaf
    $hasPartialFile = Test-Path -LiteralPath $partialCopyFile -PathType Leaf
    $destinationSize = -1L
    $integrityOk = $null
    $integrityReason = ""

    if ($hasFinalFile) {
        $destinationItem = Get-Item -LiteralPath $destinationFile -ErrorAction SilentlyContinue
        if ($destinationItem) {
            $destinationSize = [long]$destinationItem.Length
        }
    }

    $isSizeMatch = $hasFinalFile -and $sourceSize -ge 0 -and $destinationSize -eq $sourceSize
    
    # Check integrity based on mode
    if ($IntegrityMode -eq 'Quick' -and $isSizeMatch -and -not $hasPartialFile) {
        # Quick mode: Check if cached hash exists and is valid
        $cachedHash = Get-HashFromCache -DestinationFile $destinationFile -DestinationBasePath $dest -ExpectedFileSize $destinationSize
        if ($cachedHash -and $cachedHash.IsValid) {
            $integrityOk = $true
            $integrityReason = "Quick integrity check: Cached hash exists"
        } else {
            $integrityOk = $false
            $integrityReason = "Quick integrity check: No valid cached hash found"
        }
    } elseif ($IntegrityMode -eq 'True' -and $isSizeMatch -and -not $hasPartialFile) {
        # True mode: Compute hash and compare with source
        $integrityCheck = Compare-FileIntegrity -SourceFile $SourceFile -DestinationFile $destinationFile -CurrentItem $CurrentItem -TotalItems $TotalItems
        $integrityOk = $integrityCheck.IntegrityOk
        $integrityReason = $integrityCheck.Reason
    }
    
    $isComplete = $isSizeMatch -and (-not $hasPartialFile) -and ($integrityOk -ne $false)
    $needsRepair = $hasPartialFile -or ($hasFinalFile -and (-not $isSizeMatch)) -or ($integrityOk -eq $false)

    $reason = ""
    if ($hasPartialFile) {
        $reason = "Partial copy artifact exists"
    } elseif ($hasFinalFile -and (-not $isSizeMatch)) {
        $reason = "Destination size mismatch ($destinationSize bytes vs source $sourceSize bytes)"
    } elseif ($integrityOk -eq $false) {
        $reason = "File corruption detected: $integrityReason"
    }

    return [PSCustomObject]@{
        FileName               = $fileName
        IsArchive              = $false
        IsComplete             = $isComplete
        NeedsRepair            = $needsRepair
        Reason                 = $reason
        SourceSize             = $sourceSize
        SourceFile             = $SourceFile
        DestinationPath        = $DestinationPath
        DestinationFile        = $destinationFile
        PartialCopyFile        = $partialCopyFile
        HasFinalFile           = $hasFinalFile
        HasPartialFile         = $hasPartialFile
        DestinationSize        = $destinationSize
        ExtractPath            = $null
        PartialExtractPath     = $null
        CompletionMarker       = $null
        HasExtractPath         = $false
        HasPartialExtractPath  = $false
        HasCompletionMarker    = $false
        IntegrityOk            = $integrityOk
        IntegrityReason        = $integrityReason
    }
}

function Clear-IncompleteTransferArtifacts {
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$TransferState
    )

    if (-not $TransferState.NeedsRepair) {
        return $true
    }

    $pathsToRemove = @()

    if ($TransferState.IsArchive) {
        if ($TransferState.HasPartialExtractPath) {
            $pathsToRemove += $TransferState.PartialExtractPath
        }
        if ($TransferState.HasExtractPath -and (-not $TransferState.HasCompletionMarker)) {
            $pathsToRemove += $TransferState.ExtractPath
        }
    } else {
        if ($TransferState.HasPartialFile) {
            $pathsToRemove += $TransferState.PartialCopyFile
        }
        if ($TransferState.HasFinalFile -and $TransferState.SourceSize -ge 0 -and $TransferState.DestinationSize -ne $TransferState.SourceSize) {
            $pathsToRemove += $TransferState.DestinationFile
        }
        # Also remove files with integrity failures (corruption detected via hash mismatch)
        if ($TransferState.HasFinalFile -and $TransferState.IntegrityOk -eq $false) {
            $pathsToRemove += $TransferState.DestinationFile
        }
    }

    foreach ($path in ($pathsToRemove | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            Log-Message "Removed incomplete transfer artifact: $path"
        }
        catch {
            Log-Error "Failed to remove incomplete transfer artifact '$path' : $_"
            return $false
        }
    }

    return $true
}

function Test-FileAlreadyExists {
    param(
        [string]$SourceFile,
        [string]$DestinationPath
    )

    $transferState = Get-TransferState -SourceFile $SourceFile -DestinationPath $DestinationPath
    return $transferState.IsComplete
}

function Get-DriveInfo {
    param(
        [string]$DriveOrPath
    )
    
    try {
        # Get the root of the drive/path
        $root = if ($DriveOrPath -match '^[A-Z]:\\') {
            $DriveOrPath.Substring(0, 2) + "\"
        } else {
            $DriveOrPath
        }
        
        # Use WMI to get drive info
        $drive = Get-WmiObject Win32_LogicalDisk -Filter "Name='$($root -replace '\\$', '')'" -ErrorAction SilentlyContinue
        
        if (-not $drive) {
            # Fallback: try to get from filesystem
            $pathObj = Get-Item -Path $DriveOrPath -ErrorAction SilentlyContinue
            if ($pathObj -and $pathObj.Root) {
                $drive = Get-WmiObject Win32_LogicalDisk -Filter "Name='$($pathObj.Root.Name -replace '\\$', '')'" -ErrorAction SilentlyContinue
            }
        }
        
        if ($drive) {
            return @{
                TotalSize = $drive.Size
                FreeSpace = $drive.FreeSpace
                UsedSpace = $drive.Size - $drive.FreeSpace
                Filesystem = $drive.FileSystem
                VolumeName = $drive.VolumeName
                Success = $true
            }
        } else {
            return @{
                TotalSize = 0
                FreeSpace = 0
                UsedSpace = 0
                Filesystem = "Unknown"
                VolumeName = "Unknown"
                Success = $false
                Error = "Could not retrieve drive information"
            }
        }
    }
    catch {
        return @{
            TotalSize = 0
            FreeSpace = 0
            UsedSpace = 0
            Filesystem = "Unknown"
            VolumeName = "Unknown"
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Invoke-ChunkedFileCopyWithProgress {
    param(
        [string]$SourceFile,
        [string]$WorkingDestinationFile,
        [string]$FileName,
        [long]$FileSize,
        [long]$CurrentItem,
        [long]$TotalItems,
        [long]$ProcessedBytes,
        [long]$TotalBytes
    )

    $sourceStream = $null
    $destinationStream = $null
    $copySucceeded = $false
    $bytesCopiedForFile = 0L

    try {
        $bufferSize = 4MB
        $buffer = New-Object byte[] $bufferSize

        $sourceStream = [System.IO.File]::Open($SourceFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $destinationStream = [System.IO.File]::Open($WorkingDestinationFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

        $updateIntervalMs = 250
        $speedWindow = [System.Diagnostics.Stopwatch]::StartNew()
        $bytesSinceLastSpeedSample = 0L
        $currentSpeedBytesPerSecond = 0.0
        $remainingSec = 0

        while (($bytesRead = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $destinationStream.Write($buffer, 0, $bytesRead)
            $bytesCopiedForFile += $bytesRead
            $bytesSinceLastSpeedSample += $bytesRead

            if ($speedWindow.ElapsedMilliseconds -ge $updateIntervalMs -or $bytesCopiedForFile -eq $FileSize) {
                if ($speedWindow.Elapsed.TotalSeconds -gt 0) {
                    $currentSpeedBytesPerSecond = $bytesSinceLastSpeedSample / $speedWindow.Elapsed.TotalSeconds
                }

                $speedWindow.Restart()
                $bytesSinceLastSpeedSample = 0

                $filePercentComplete = if ($FileSize -gt 0) {
                    [math]::Round(($bytesCopiedForFile / $FileSize) * 100, 2)
                } else {
                    100
                }

                $overallBytesDone = $ProcessedBytes + $bytesCopiedForFile
                $overallPercentComplete = if ($TotalBytes -gt 0) {
                    [math]::Round(($overallBytesDone / $TotalBytes) * 100, 2)
                } else {
                    100
                }

                if ($currentSpeedBytesPerSecond -gt 0 -and $FileSize -gt $bytesCopiedForFile) {
                    $remainingSec = [int][math]::Ceiling(($FileSize - $bytesCopiedForFile) / $currentSpeedBytesPerSecond)
                } else {
                    $remainingSec = 0
                }

                $etaText = if ($remainingSec -gt 0) {
                    [TimeSpan]::FromSeconds($remainingSec).ToString('hh\:mm\:ss')
                } else {
                    "00:00:00"
                }

                $speedMBs = [math]::Round($currentSpeedBytesPerSecond / 1MB, 2)

                Write-Progress -Activity "Copying files to drive" `
                    -Status "Item $CurrentItem/$TotalItems | $FileName | File $filePercentComplete% | Total $overallPercentComplete%" `
                    -PercentComplete $overallPercentComplete `
                    -CurrentOperation "File: $([math]::Round($bytesCopiedForFile / 1GB, 2))/$([math]::Round($FileSize / 1GB, 2)) GB | Speed: $speedMBs MB/s | ETA: $etaText"
            }
        }

        $destinationStream.Flush()
        $copySucceeded = $true

        return @{
            Success = $true
            BytesCopied = $bytesCopiedForFile
        }
    }
    catch {
        return @{
            Success = $false
            BytesCopied = $bytesCopiedForFile
            Error = $_.Exception.Message
        }
    }
    finally {
        if ($destinationStream) {
            $destinationStream.Dispose()
        }
        if ($sourceStream) {
            $sourceStream.Dispose()
        }

        # Cleanup partial destination file on failed copy.
        if (-not $copySucceeded -and (Test-Path -LiteralPath $WorkingDestinationFile -PathType Leaf)) {
            Remove-Item -LiteralPath $WorkingDestinationFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Copy-FileWithProgress {
    param(
        [string]$SourceFile,
        [string]$DestinationPath,
        [long]$CurrentItem,
        [long]$TotalItems,
        [long]$ProcessedBytes,
        [long]$TotalBytes,
        [string]$IntegrityMode = 'None'
    )
    
    try {
        $fileName = Split-Path $SourceFile -Leaf
        $transferState = Get-TransferState -SourceFile $SourceFile -DestinationPath $DestinationPath -IntegrityMode 'None'

        # If file passed scan phase and is in filesToCopy, it needs transfer
        # Only check for cleanup/repair, don't re-validate completion
        # (Integrity was already checked in scan phase if enabled)
        if ($transferState.NeedsRepair) {
            Log-Message "Detected incomplete transfer for $fileName ($($transferState.Reason)); resetting destination state"
            $cleanupSucceeded = Clear-IncompleteTransferArtifacts -TransferState $transferState
            if (-not $cleanupSucceeded) {
                return @{ Success = $false; Skipped = $false; BytesCopied = 0 }
            }
        }
        
        # Ensure destination directory exists
        if (-not (Test-Path -LiteralPath $DestinationPath)) {
            New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction Stop | Out-Null
        }
        
        # Get file size
        $file = Get-Item -LiteralPath $SourceFile -ErrorAction Stop
        $fileSize = $file.Length
        
        # Check if it's an archive
        $isArchive = Get-IsArchiveFile -FileName $fileName
        
        if ($isArchive) {
            Log-Message "Extracting archive: $fileName ($([math]::Round($fileSize / 1GB, 2)) GB)"
            $archivePaths = Get-ArchiveTransferPaths -DestinationPath $DestinationPath -FileName $fileName

            if (Test-Path -LiteralPath $archivePaths.PartialExtractPath) {
                Remove-Item -LiteralPath $archivePaths.PartialExtractPath -Recurse -Force -ErrorAction SilentlyContinue
            }

            $extractResult = Extract-TarArchive -ArchivePath $SourceFile -DestinationPath $archivePaths.PartialExtractPath
            if (-not $extractResult.Success) {
                if (Test-Path -LiteralPath $archivePaths.PartialExtractPath) {
                    Remove-Item -LiteralPath $archivePaths.PartialExtractPath -Recurse -Force -ErrorAction SilentlyContinue
                }
                return @{ Success = $false; Skipped = $false; BytesCopied = 0 }
            }

            try {
                if (Test-Path -LiteralPath $archivePaths.ExtractPath -PathType Container) {
                    Remove-Item -LiteralPath $archivePaths.ExtractPath -Recurse -Force -ErrorAction Stop
                }

                Move-Item -LiteralPath $archivePaths.PartialExtractPath -Destination $archivePaths.ExtractPath -ErrorAction Stop

                $completionInfo = @(
                    "Archive extraction completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
                    "Source archive: $fileName",
                    "Source size bytes: $fileSize"
                )
                
                if ($extractResult.ExcludedFiles.Count -gt 0) {
                    $completionInfo += "Skipped corrupted files: $($extractResult.ExcludedFiles -join ', ')"
                    Log-Message "Warning: Extracted archive with $($extractResult.ExcludedFiles.Count) file(s) skipped due to corruption: $($extractResult.ExcludedFiles -join ', ')"
                }
                
                $completionInfo | Out-File -FilePath $archivePaths.CompletionMarker -Encoding ascii -Force
            }
            catch {
                Log-Error "Failed finalizing archive extraction for $fileName : $_"
                if (Test-Path -LiteralPath $archivePaths.PartialExtractPath) {
                    Remove-Item -LiteralPath $archivePaths.PartialExtractPath -Recurse -Force -ErrorAction SilentlyContinue
                }
                return @{ Success = $false; Skipped = $false; BytesCopied = 0 }
            }
        } else {
            Log-Message "Copying: $fileName ($([math]::Round($fileSize / 1GB, 2)) GB)"
            $fullDestPath = Join-Path $DestinationPath $fileName
            $partialCopyPath = $fullDestPath + $partialCopySuffix

            if (Test-Path -LiteralPath $partialCopyPath -PathType Leaf) {
                Remove-Item -LiteralPath $partialCopyPath -Force -ErrorAction SilentlyContinue
            }

            $copyState = Invoke-ChunkedFileCopyWithProgress `
                -SourceFile $SourceFile `
                -WorkingDestinationFile $partialCopyPath `
                -FileName $fileName `
                -FileSize $fileSize `
                -CurrentItem $CurrentItem `
                -TotalItems $TotalItems `
                -ProcessedBytes $ProcessedBytes `
                -TotalBytes $TotalBytes

            if (-not $copyState.Success) {
                Log-Error "Failed while streaming copy for $SourceFile : $($copyState.Error)"
                return @{ Success = $false; Skipped = $false; BytesCopied = 0 }
            }

            $copiedInfo = Get-Item -LiteralPath $partialCopyPath -ErrorAction SilentlyContinue
            if (-not $copiedInfo -or $copiedInfo.Length -ne $fileSize) {
                $copiedBytes = if ($copiedInfo) { [long]$copiedInfo.Length } else { 0 }
                Log-Error "Copied file failed validation for $fileName ($copiedBytes bytes vs source $fileSize bytes)"
                if (Test-Path -LiteralPath $partialCopyPath -PathType Leaf) {
                    Remove-Item -LiteralPath $partialCopyPath -Force -ErrorAction SilentlyContinue
                }
                return @{ Success = $false; Skipped = $false; BytesCopied = 0 }
            }

            try {
                Move-Item -LiteralPath $partialCopyPath -Destination $fullDestPath -Force -ErrorAction Stop
            }
            catch {
                Log-Error "Failed to finalize copy for $fileName : $_"
                if (Test-Path -LiteralPath $partialCopyPath -PathType Leaf) {
                    Remove-Item -LiteralPath $partialCopyPath -Force -ErrorAction SilentlyContinue
                }
                return @{ Success = $false; Skipped = $false; BytesCopied = 0 }
            }
            
            # Compute and cache hash if integrity mode is enabled
            if ($IntegrityMode -ne 'None') {
                Log-Message "Computing hash for integrity verification: $fileName"
                $hash = Get-FileMD5 -FilePath $fullDestPath -ProgressCallback {
                    param([long]$BytesRead, [long]$FileSize)
                    $filePercent = if ($FileSize -gt 0) {
                        [math]::Min(100, [math]::Round(($BytesRead / $FileSize) * 100, 2))
                    } else { 100 }
                    Write-Progress -Activity "Computing integrity hash" `
                        -Status "$fileName | $filePercent%" `
                        -PercentComplete $filePercent `
                        -CurrentOperation "Hashing $([math]::Round($BytesRead / 1GB, 2))/$([math]::Round($FileSize / 1GB, 2)) GB"
                }
                
                if ($hash) {
                    $saved = Save-HashToCache -DestinationFile $fullDestPath -DestinationBasePath $dest -Hash $hash -FileSize $fileSize
                    if ($saved) {
                        Log-Message "Integrity hash cached: $fileName"
                    } else {
                        Log-Error "Failed to cache integrity hash for $fileName (transfer succeeded)"
                    }
                } else {
                    Log-Error "Failed to compute integrity hash for $fileName (transfer succeeded)"
                }
                
                Write-Progress -Activity "Computing integrity hash" -Completed
            }
        }
        
        # Calculate progress
        $totalProcessed = $ProcessedBytes + $fileSize
        $percentComplete = if ($TotalBytes -gt 0) { [math]::Round(($totalProcessed / $TotalBytes) * 100) } else { 0 }
        
        # Show progress bar
        $progressParams = @{
            Activity        = "Copying files to drive"
            Status          = "$fileName"
            PercentComplete = $percentComplete
            CurrentOperation = "Item $CurrentItem of $TotalItems | $([math]::Round($totalProcessed / 1GB, 2)) GB / $([math]::Round($TotalBytes / 1GB, 2)) GB"
        }
        Write-Progress @progressParams
        
        return @{ 
            Success = $true
            Skipped = $false
            BytesCopied = $fileSize
            DestinationPath = if ($isArchive) {
                (Get-ArchiveTransferPaths -DestinationPath $DestinationPath -FileName $fileName).ExtractPath
            } else {
                Join-Path $DestinationPath $fileName
            }
        }
    }
    catch {
        Log-Error "Failed to copy $SourceFile : $_"
        return @{ Success = $false; Skipped = $false; BytesCopied = 0 }
    }
}

# Main execution
Log-Message "=== Drive Builder Started ==="
Log-Message "Destination: $dest"
Log-Message "DryRun: $DryRun"
if ($IntegrityMode -eq 'Quick') {
    Log-Message "Integrity Mode: QUICK (resume with cached hashes - fast)"
} elseif ($IntegrityMode -eq 'True') {
    Log-Message "Integrity Mode: TRUE (full verification - slow but thorough)"
} else {
    Log-Message "Integrity Mode: None (use -IntegrityMode Quick or True for corruption detection)"
}
Log-Message "Excluded categories: $excludedCategorySummary"

# Find and load CSV files
$csvFiles = @()
foreach ($pattern in $SourceCsvPatterns) {
    $found = Get-ChildItem -Filter $pattern -File -ErrorAction SilentlyContinue
    if ($found) {
        $csvFiles += $found
    }
}

if ($csvFiles.Count -eq 0) {
    Stop-DriveBuilder -Message "No CSV files found matching patterns: $($SourceCsvPatterns -join ', ')"
}

Log-Message "Found $($csvFiles.Count) CSV file(s): $($csvFiles.Name -join ', ')"

# Read all items from CSV files
$allItems = @()
foreach ($csvFile in $csvFiles) {
    Log-Message "Reading CSV: $($csvFile.Name)"
    $items = Import-Csv -Path $csvFile.FullName -ErrorAction SilentlyContinue
    if ($items) {
        $allItems += $items
    }
}

Log-Message "Total items to process: $($allItems.Count)"

if ($allItems.Count -eq 0) {
    Stop-DriveBuilder -Message "No items found in CSV files"
}

# Filter to valid files and calculate total size and check for existing files
$filesToCopy = @()
$alreadyExists = @()
$partialTransfers = @()
$excludedItems = @()
$totalBytes = 0

Log-Message "Scanning destination for existing files..."
if ($IntegrityMode -ne 'None') {
    Write-Host ""
    if ($IntegrityMode -eq 'Quick') {
        Write-Host "Integrity Mode: QUICK - Files with cached hashes will be considered complete" -ForegroundColor Cyan
    } elseif ($IntegrityMode -eq 'True') {
        Write-Host "Integrity Mode: TRUE - All hashes will be verified (slow)" -ForegroundColor Yellow
    }
    Write-Host ""
}

$itemIndex = 0
$processedBytes = 0
$itemsToCheck = 0
$itemsVerified = 0

foreach ($item in $allItems) {
    $itemIndex++
    
    if ([string]::IsNullOrWhiteSpace($item.FullPath)) {
        continue
    }

    # Do not export files that are still uncategorized/personal.
    if (Test-IsExcludedCategory -AutoCategory $item.AutoCategory) {
        $excludedItems += [PSCustomObject]@{
            FileName = $item.FileName
            AutoCategory = $item.AutoCategory
        }
        continue
    }
    
    $sourcePath = $item.FullPath
    $fileName = Split-Path $sourcePath -Leaf
    

    if ($IntegrityMode -ne 'None') {
        Write-Progress -Id $integrityProgressId -Activity "Verifying file integrity (MD5)" -Completed
    }
    # Show scan progress using periodic updates every 20 items
    if ($itemIndex % 20 -eq 0) {
        $percentDone = if ($allItems.Count -gt 0) { [int](($itemIndex / $allItems.Count) * 100) } else { 0 }
        Log-Message "Progress: $itemIndex/$($allItems.Count) files scanned ($percentDone%)"
    }
    
    # Verify file exists
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        Stop-DriveBuilder -Message "Source file not found: $sourcePath"
    }
    
    # Determine destination folder
    $folderInfo = Get-DetermineFolderName -AutoCategory $item.AutoCategory -ShowName $item.ShowName -FileName $item.FileName
    
    # First pass: check state WITHOUT integrity (fast)
    $transferState = Get-TransferState -SourceFile $sourcePath -DestinationPath $folderInfo.FullPath -IntegrityMode 'None' -CurrentItem $itemIndex -TotalItems $allItems.Count

    # If integrity checking is enabled and destination file exists with correct size, verify hash
    # (We check files that appear complete by size, since corruption may not change file size)
    if ($IntegrityMode -ne 'None' -and $transferState.HasFinalFile -and -not $transferState.HasPartialFile -and $transferState.DestinationSize -eq $transferState.SourceSize) {
        $itemsToCheck++
        # Re-check with integrity enabled to verify hash
        $transferState = Get-TransferState -SourceFile $sourcePath -DestinationPath $folderInfo.FullPath -IntegrityMode $IntegrityMode -CurrentItem $itemIndex -TotalItems $allItems.Count
        $itemsVerified++
    }

    # Check destination transfer state.
    if ($transferState.IsComplete) {
        $alreadyExists += @{
            FileName = $item.FileName
            DestinationPath = $folderInfo.FullPath
        }
    } else {
        if ($transferState.NeedsRepair) {
            $partialTransfers += @{
                FileName = $item.FileName
                DestinationPath = $folderInfo.FullPath
                Reason = $transferState.Reason
            }
        }

        $filesToCopy += $item
        
        # Sum up file sizes
        if ([string]::IsNullOrWhiteSpace($item.SizeGB)) {
            if ($transferState.SourceSize -ge 0) {
                $totalBytes += $transferState.SourceSize
            } else {
                $fileInfo = Get-Item -LiteralPath $sourcePath
                $totalBytes += $fileInfo.Length
            }
        } else {
            $totalBytes += [long]([double]$item.SizeGB * 1GB)
        }
    }
}

# Progress bar cleanup was here but removed to prevent UI conflicts with logging output

# Add whitespace for readability
Write-Host ""

if ($alreadyExists.Count -gt 0) {
    Log-Message "Found $($alreadyExists.Count) file(s) already on destination - will skip"
    if ($alreadyExists.Count -le 10) {
        foreach ($existing in $alreadyExists) {
            Log-Message "  → $($existing.FileName)"
        }
    } else {
        foreach ($existing in $alreadyExists | Select-Object -First 5) {
            Log-Message "  → $($existing.FileName)"
        }
        Log-Message "  → ... and $($alreadyExists.Count - 5) more"
    }
}

if ($partialTransfers.Count -gt 0) {
    # Separate corruption issues from other issues
    $corruptedFiles = @($partialTransfers | Where-Object { $_.Reason -like "*File corruption*" })
    $otherIssues = @($partialTransfers | Where-Object { $_.Reason -notlike "*File corruption*" })
    
    if ($corruptedFiles.Count -gt 0) {
        Write-Host ""
        Write-Host "⚠️  CORRUPTION DETECTED: $($corruptedFiles.Count) file(s) have mismatched hashes and will be re-transferred" -ForegroundColor Red -BackgroundColor Black
        Write-Host ""
        Log-Message "CORRUPTION ALERT: Found $($corruptedFiles.Count) corrupted file(s)"
        if ($corruptedFiles.Count -le 10) {
            foreach ($corrupt in $corruptedFiles) {
                Write-Host "  ❌ $($corrupt.FileName)" -ForegroundColor Red
                Log-Message "  [CORRUPT] $($corrupt.FileName) - $($corrupt.Reason)"
            }
        } else {
            foreach ($corrupt in $corruptedFiles | Select-Object -First 5) {
                Write-Host "  ❌ $($corrupt.FileName)" -ForegroundColor Red
                Log-Message "  [CORRUPT] $($corrupt.FileName) - $($corrupt.Reason)"
            }
            Write-Host "  ... and $($corruptedFiles.Count - 5) more corrupted files" -ForegroundColor Red
            Log-Message "  [CORRUPT] ... and $($corruptedFiles.Count - 5) more"
        }
        Write-Host ""
    }
    
    if ($otherIssues.Count -gt 0) {
        Log-Message "Detected $($otherIssues.Count) incomplete transfer(s) - they will be redone"
        if ($otherIssues.Count -le 10) {
            foreach ($partial in $otherIssues) {
                Log-Message "  [redo] $($partial.FileName) ($($partial.Reason))"
            }
        } else {
            foreach ($partial in $otherIssues | Select-Object -First 5) {
                Log-Message "  [redo] $($partial.FileName) ($($partial.Reason))"
            }
            Log-Message "  [redo] ... and $($otherIssues.Count - 5) more"
        }
    }
}

if ($excludedItems.Count -gt 0) {
    Log-Message "Excluded $($excludedItems.Count) file(s) by category policy ($excludedCategorySummary)"
    $excludedByCategory = $excludedItems | Group-Object {
        if ([string]::IsNullOrWhiteSpace($_.AutoCategory)) { '(empty)' } else { $_.AutoCategory }
    } | Sort-Object Name
    foreach ($group in $excludedByCategory) {
        Log-Message "  - $($group.Name): $($group.Count)"
    }
}

Log-Message "Valid files to copy: $($filesToCopy.Count)"
Log-Message "Total data size to copy: $([math]::Round($totalBytes / 1GB, 2)) GB"

if ($IntegrityMode -ne 'None') {
    Log-Message "Integrity verification: checked $itemsToCheck file(s) for corruption using $IntegrityMode mode"
}


if ($filesToCopy.Count -eq 0) {
    Log-Message "No exportable files to copy after filtering and existing-file checks."
    Log-Message "Already present: $($alreadyExists.Count)"
    Log-Message "Excluded by category: $($excludedItems.Count)"
    Write-LogsToDisk
    exit 0
}

# Check drive space
Log-Message "Checking destination drive capacity..."
$driveInfo = Get-DriveInfo -DriveOrPath $dest

if (-not $driveInfo.Success) {
    Stop-DriveBuilder -Message "Could not determine drive capacity: $($driveInfo.Error). Please verify the destination drive is accessible and properly formatted"
}

Log-Message "Destination: $($driveInfo.VolumeName) ($($driveInfo.Filesystem))"
Log-Message "Drive Total: $([math]::Round($driveInfo.TotalSize / 1GB, 2)) GB"
Log-Message "Drive Free: $([math]::Round($driveInfo.FreeSpace / 1GB, 2)) GB"
Log-Message "Drive Used: $([math]::Round($driveInfo.UsedSpace / 1GB, 2)) GB"

if ($totalBytes -gt $driveInfo.FreeSpace) {
    $needed = [math]::Round($totalBytes / 1GB, 2)
    $available = [math]::Round($driveInfo.FreeSpace / 1GB, 2)
    $shortBy = [math]::Round(($totalBytes - $driveInfo.FreeSpace) / 1GB, 2)
    
    Log-Message "INSUFFICIENT DISK SPACE"
    Write-Host ""
    Write-Host "Files to copy require:  $needed GB"
    Write-Host "Available free space:   $available GB"
    Write-Host "Short by:               $shortBy GB"
    Write-Host ""
    Write-Host "You can:"
    Write-Host "  1. Delete files from the destination drive to free up space"
    Write-Host "  2. Use a larger drive"
    Write-Host "  3. Select only some files to copy (modify CSV patterns)"
    Write-Host ""
    Stop-DriveBuilder -Message "INSUFFICIENT DISK SPACE: Drive does not have enough space for this transfer"
}

$safetyMargin = [math]::Round($driveInfo.FreeSpace * 0.05) # 5% safety margin
if (($totalBytes + $safetyMargin) -gt $driveInfo.FreeSpace) {
    $margin = [math]::Round($safetyMargin / 1GB, 2)
    Log-Message "WARNING: Only $margin GB safety margin remaining after copy"
}

if ($DryRun) {
    Log-Message "=== DRY RUN - No files will be copied ==="
    Log-Message "New files to copy:"
    foreach ($item in $filesToCopy) {
        $folderInfo = Get-DetermineFolderName -AutoCategory $item.AutoCategory -ShowName $item.ShowName -FileName $item.FileName
        Log-Message "  -> $($item.FileName) -> $($folderInfo.FullPath)"
    }
    
    if ($alreadyExists.Count -gt 0) {
        Log-Message "Files already on destination:"
        foreach ($existing in $alreadyExists) {
            Log-Message "  [present] $($existing.FileName) (in $($existing.DestinationPath))"
        }
    }

    if ($partialTransfers.Count -gt 0) {
        Log-Message "Incomplete transfers detected (will be redone):"
        foreach ($partial in $partialTransfers) {
            Log-Message "  [redo] $($partial.FileName) (in $($partial.DestinationPath))"
        }
    }
    
    Log-Message "=== DRY RUN Summary ==="
    Log-Message "Files to copy: $($filesToCopy.Count)"
    Log-Message "Data to copy: $([math]::Round($totalBytes / 1GB, 2)) GB"
    Log-Message "Already present: $($alreadyExists.Count)"
    Log-Message "Partial/incomplete detected: $($partialTransfers.Count)"
    Log-Message "Excluded by category: $($excludedItems.Count)"
    Log-Message "=== DRY RUN Complete ==="
    Log-Message ""
    Log-Message "=== Drive Space Check ==="
    Log-Message "Available free space: $([math]::Round($driveInfo.FreeSpace / 1GB, 2)) GB"
    Log-Message "Space needed: $([math]::Round($totalBytes / 1GB, 2)) GB"
    $spaceAfterCopy = $driveInfo.FreeSpace - $totalBytes
    if ($spaceAfterCopy -ge 0) {
        Log-Message "Space remaining after copy: $([math]::Round($spaceAfterCopy / 1GB, 2)) GB [ok]"
    }
    else {
        Log-Message "INSUFFICIENT SPACE [not ok]"
    }
    
    Write-LogsToDisk
    exit 0
}

# Perform actual copy operations
$processedBytes = 0
$successCount = 0
$failureCount = 0
$skipCount = 0

Log-Message "=== Starting Copy Operations ==="

for ($i = 0; $i -lt $filesToCopy.Count; $i++) {
    $item = $filesToCopy[$i]
    $currentItem = $i + 1
    
    $folderInfo = Get-DetermineFolderName -AutoCategory $item.AutoCategory -ShowName $item.ShowName -FileName $item.FileName
    
    $copyResult = Copy-FileWithProgress `
        -SourceFile $item.FullPath `
        -DestinationPath $folderInfo.FullPath `
        -CurrentItem $currentItem `
        -TotalItems $filesToCopy.Count `
        -ProcessedBytes $processedBytes `
        -TotalBytes $totalBytes `
        -IntegrityMode $IntegrityMode
    
    if ($copyResult.Success) {
        if ($copyResult.Skipped) {
            $skipCount++
        } else {
            $successCount++
            $processedBytes += $copyResult.BytesCopied
        }
    } else {
        $failureCount++
        Log-Error "Transfer failed for item $currentItem/$($filesToCopy.Count): $($item.FullPath)"
        # Continue processing remaining files instead of aborting
    }
}

Write-Progress -Activity "Copying files to drive" -Completed

Log-Message "=== Copy Summary ==="
Log-Message "Copied:        $successCount"
Log-Message "Skipped (new): $skipCount"
Log-Message "Already Present: $($alreadyExists.Count)"
Log-Message "Partial/incomplete detected: $($partialTransfers.Count)"
Log-Message "Excluded by category: $($excludedItems.Count)"
Log-Message "Failed:        $failureCount"
Log-Message "Total Data Copied: $([math]::Round($processedBytes / 1GB, 2)) GB"
$grandTotal = $successCount + $skipCount + $alreadyExists.Count + $excludedItems.Count
Log-Message "Grand Total Files Evaluated: $grandTotal"

# Write logs to files
Write-LogsToDisk

Log-Message "=== Drive Builder Complete ==="
Log-Message "Log file: $driveBuilderLog"
if ($errorEntries.Count -gt 0) {
    Log-Message "Error log: $errorLog"
}

# Exit with appropriate code
if ($failureCount -gt 0) {
    Log-Message "WARNING: $failureCount file(s) failed to transfer"
    exit 1
}
exit 0
