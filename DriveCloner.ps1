param(
    [Parameter(Mandatory=$true)]
    [string]$SourceDrive,
    
    [Parameter(Mandatory=$true)]
    [string]$DestinationDrive,
    
    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipHashComparison = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force = $false
)

# Normalize drive paths
$source = $SourceDrive.TrimEnd('\')
if ($source -match '^[A-Z]:$') {
    $source = $source + "\"
}

$dest = $DestinationDrive.TrimEnd('\')
if ($dest -match '^[A-Z]:$') {
    $dest = $dest + "\"
}

# Constants
$partialCopySuffix = ".__partial_copy__"
$integrityCacheFolder = ".integrity_cache"
$cloneManifestFile = ".drive_clone_manifest.csv"
$integrityProgressId = 2

# Logging
$logsFolder = "logs"
if (-not (Test-Path -LiteralPath $logsFolder)) {
    New-Item -ItemType Directory -Path $logsFolder | Out-Null
}
$driveClonerLog = Join-Path $logsFolder "drive_cloner.log"
$errorLog = Join-Path $logsFolder "drive_cloner_errors.log"
$verificationLog = Join-Path $logsFolder "drive_cloner_verification.log"

$logEntries = New-Object System.Collections.Generic.List[String]
$errorEntries = New-Object System.Collections.Generic.List[String]
$verificationEntries = New-Object System.Collections.Generic.List[String]

function Write-LogsToDisk {
    try {
        if ($logEntries.Count -gt 0) {
            $logEntries | Out-File -FilePath $driveClonerLog -Encoding UTF8
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
    
    try {
        if ($verificationEntries.Count -gt 0) {
            $verificationEntries | Out-File -FilePath $verificationLog -Encoding UTF8
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

function Log-Verification {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] $Message"
    $verificationEntries.Add($entry)
}

function Stop-DriveCloner {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [int]$ExitCode = 1
    )

    Log-Error $Message

    try {
        Write-Progress -Activity "Cloning drive" -Completed
        Write-Progress -Id $integrityProgressId -Activity "Generating verification hashes" -Completed
    }
    catch {
        # Best-effort cleanup of progress UI.
    }

    Log-Message "=== Drive Cloner Aborted ==="
    Log-Message "Log file: $driveClonerLog"
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
        -Activity "Generating verification hashes" `
        -Status (Get-TruncatedText -Text $Status -MaxLength $statusMaxLength) `
        -PercentComplete $safePercent `
        -CurrentOperation (Get-TruncatedText -Text $CurrentOperation -MaxLength $operationMaxLength)
}

function Get-HashCachePath {
    param(
        [string]$FilePath,
        [string]$BasePath
    )
    
    # Get relative path from base to file
    $fileName = Split-Path $FilePath -Leaf
    $parentPath = Split-Path $FilePath -Parent
    
    # Build cache folder path
    $cacheRoot = Join-Path $BasePath $integrityCacheFolder
    
    # If file is in a subfolder, maintain structure in cache
    if ($parentPath -ne $BasePath) {
        $relativePath = $parentPath.Substring($BasePath.Length).TrimStart('\')
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
        [string]$FilePath,
        [string]$BasePath,
        [string]$Hash,
        [long]$FileSize
    )
    
    try {
        $cachePaths = Get-HashCachePath -FilePath $FilePath -BasePath $BasePath
        
        # Ensure cache folder exists
        if (-not (Test-Path -LiteralPath $cachePaths.CacheFolder)) {
            New-Item -ItemType Directory -Path $cachePaths.CacheFolder -Force -ErrorAction Stop | Out-Null
        }
        
        # Write hash file with metadata
        $cacheData = @{
            Hash = $Hash
            FileSize = $FileSize
            Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            FileName = (Split-Path $FilePath -Leaf)
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
        [string]$FilePath,
        [string]$BasePath,
        [long]$ExpectedFileSize = -1
    )
    
    try {
        $cachePaths = Get-HashCachePath -FilePath $FilePath -BasePath $BasePath
        
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

function Get-FileMD5 {
    param(
        [string]$FilePath,
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

function Copy-FileWithProgress {
    param(
        [string]$SourceFile,
        [string]$DestinationFile,
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
    $partialDestFile = $DestinationFile + $partialCopySuffix

    try {
        $fileName = Split-Path $SourceFile -Leaf
        $displayName = Get-TruncatedText -Text $fileName -MaxLength 40
        
        $bufferSize = 4MB
        $buffer = New-Object byte[] $bufferSize

        $sourceStream = [System.IO.File]::Open($SourceFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $destinationStream = [System.IO.File]::Open($partialDestFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

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

                Write-Progress -Activity "Cloning drive" `
                    -Status "Item $CurrentItem/$TotalItems | $displayName | File $filePercentComplete% | Total $overallPercentComplete%" `
                    -PercentComplete $overallPercentComplete `
                    -CurrentOperation "File: $([math]::Round($bytesCopiedForFile / 1GB, 2))/$([math]::Round($FileSize / 1GB, 2)) GB | Speed: $speedMBs MB/s | ETA: $etaText"
            }
        }

        $destinationStream.Flush()
        $destinationStream.Dispose()
        $destinationStream = $null
        $sourceStream.Dispose()
        $sourceStream = $null
        
        # Verify size before renaming
        $copiedFileInfo = Get-Item -LiteralPath $partialDestFile
        if ($copiedFileInfo.Length -ne $FileSize) {
            throw "Copied file size mismatch: expected $FileSize bytes, got $($copiedFileInfo.Length) bytes"
        }
        
        # Atomic rename from partial to final name
        Move-Item -LiteralPath $partialDestFile -Destination $DestinationFile -Force -ErrorAction Stop
        
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
        if (-not $copySucceeded -and (Test-Path -LiteralPath $partialDestFile -PathType Leaf)) {
            Remove-Item -LiteralPath $partialDestFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-RelativePath {
    param(
        [string]$Path,
        [string]$BasePath
    )
    
    if ($Path.StartsWith($BasePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($BasePath.Length).TrimStart('\')
    }
    
    return $Path
}

# Verify source exists
if (-not (Test-Path -LiteralPath $source)) {
    Stop-DriveCloner "Source drive/path does not exist: $source"
}

# Verify destination exists
if (-not (Test-Path -LiteralPath $dest)) {
    Stop-DriveCloner "Destination drive/path does not exist: $dest"
}

# Verify source and destination are different
if ($source -eq $dest) {
    Stop-DriveCloner "Source and destination must be different drives"
}

# Verify destination is writable
$testFile = Join-Path $dest ".drive_cloner_test_$([guid]::NewGuid().ToString().Substring(0,8))"
try {
    $null = New-Item -ItemType File -Path $testFile -Force -ErrorAction Stop
    Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
}
catch {
    Stop-DriveCloner "Destination drive is not writable: $dest`nError: $_"
}

Log-Message "=== Drive Cloner Starting ==="
Log-Message "Source: $source"
Log-Message "Destination: $dest"
Log-Message "Dry Run: $DryRun"
Log-Message ""

# Scan source drive for all files
Log-Message "Scanning source drive for files..."
Write-Progress -Activity "Cloning drive" -Status "Scanning source drive..." -PercentComplete 0

# Define accepted media file extensions
$videoExtensions = @('.mkv', '.mp4', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.mpg', '.mpeg', '.m2ts', '.ts', '.vob', '.ogv', '.3gp', '.divx')
$audioExtensions = @('.mp3', '.flac', '.m4a', '.aac', '.wav', '.ogg', '.wma', '.opus', '.alac', '.ape')
$acceptedExtensions = $videoExtensions + $audioExtensions

$allFiles = @()
$totalSize = 0L

try {
    $allFiles = Get-ChildItem -LiteralPath $source -Recurse -File -Force | Where-Object {
        $ext = $_.Extension.ToLower()
        
        # Exclude $RECYCLE.BIN folder
        $_.FullName -notmatch '\\\$RECYCLE\.BIN\\' -and
        # Exclude integrity cache folders and other DriveBuilder artifacts
        $_.FullName -notmatch '\\\.integrity_cache\\' -and
        $_.Name -ne '.drive_builder_test' -and
        $_.Name -ne '.drive_builder_extract_complete' -and
        $_.Name -ne '.drive_builder_completed_archives' -and
        $_.Name -ne $cloneManifestFile -and
        -not $_.Name.EndsWith($partialCopySuffix) -and
        # Only include common media file formats
        ($acceptedExtensions -contains $ext)
    }
    
    $totalSize = ($allFiles | Measure-Object -Property Length -Sum).Sum
}
catch {
    Stop-DriveCloner "Failed to scan source drive: $_"
}

$fileCount = $allFiles.Count
Log-Message "Found $fileCount files totaling $([math]::Round($totalSize / 1GB, 2)) GB"

if ($fileCount -eq 0) {
    Log-Message "No files to clone. Exiting."
    Write-LogsToDisk
    exit 0
}

# Check destination space
try {
    $destVolume = Get-PSDrive -Name ($dest.Substring(0, 1)) -ErrorAction Stop
    $freeSpace = $destVolume.Free
    $requiredSpace = $totalSize
    $safetyMargin = 1GB  # 1GB safety margin
    
    Log-Message "Destination free space: $([math]::Round($freeSpace / 1GB, 2)) GB"
    Log-Message "Required space: $([math]::Round($requiredSpace / 1GB, 2)) GB"
    
    if ($freeSpace -lt ($requiredSpace + $safetyMargin)) {
        $shortfall = ($requiredSpace + $safetyMargin) - $freeSpace
        Stop-DriveCloner "Insufficient space on destination drive. Need $([math]::Round($shortfall / 1GB, 2)) GB more."
    }
}
catch {
    Log-Message "Warning: Could not verify destination space: $_"
    if (-not $Force) {
        Stop-DriveCloner "Use -Force to bypass space check"
    }
}

Log-Message ""

# Load manifest if it exists (for resume)
$manifestPath = Join-Path $dest $cloneManifestFile
$manifest = @{}
if (Test-Path -LiteralPath $manifestPath) {
    try {
        $manifestData = Import-Csv -LiteralPath $manifestPath
        foreach ($entry in $manifestData) {
            $manifest[$entry.RelativePath] = @{
                Hash = $entry.Hash
                FileSize = [long]$entry.FileSize
                Timestamp = $entry.Timestamp
            }
        }
        Log-Message "Loaded resume manifest with $($manifest.Count) entries"
    }
    catch {
        Log-Message "Warning: Could not load manifest, starting fresh: $_"
    }
}

# Phase 1: Copy files
Log-Message "=== Phase 1: Copying Files ==="
$copiedCount = 0
$skippedCount = 0
$errorCount = 0
$processedBytes = 0L
$currentItem = 0

foreach ($file in $allFiles) {
    $currentItem++
    $relativePath = Get-RelativePath -Path $file.FullName -BasePath $source
    $destFilePath = Join-Path $dest $relativePath
    $destDir = Split-Path $destFilePath -Parent
    
    # Check if file already exists and has valid hash
    $skipCopy = $false
    if (Test-Path -LiteralPath $destFilePath -PathType Leaf) {
        $destFile = Get-Item -LiteralPath $destFilePath
        if ($destFile.Length -eq $file.Length) {
            # Check if we have a hash for this file
            $cachedHash = Get-HashFromCache -FilePath $destFilePath -BasePath $dest -ExpectedFileSize $file.Length
            if ($cachedHash -and $cachedHash.IsValid) {
                $skipCopy = $true
                $skippedCount++
                Log-Message "Skipping (already copied): $relativePath"
            }
        }
    }
    
    if (-not $skipCopy) {
        # Ensure destination directory exists
        if (-not (Test-Path -LiteralPath $destDir)) {
            if (-not $DryRun) {
                New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null
            }
        }
        
        if ($DryRun) {
            Log-Message "Would copy: $relativePath ($([math]::Round($file.Length / 1MB, 2)) MB)"
            $copiedCount++
        }
        else {
            # Remove partial copy if it exists
            $partialDestFile = $destFilePath + $partialCopySuffix
            if (Test-Path -LiteralPath $partialDestFile) {
                Remove-Item -LiteralPath $partialDestFile -Force -ErrorAction SilentlyContinue
            }
            
            $copyResult = Copy-FileWithProgress `
                -SourceFile $file.FullName `
                -DestinationFile $destFilePath `
                -FileSize $file.Length `
                -CurrentItem $currentItem `
                -TotalItems $fileCount `
                -ProcessedBytes $processedBytes `
                -TotalBytes $totalSize
            
            if ($copyResult.Success) {
                Log-Message "Copied: $relativePath ($([math]::Round($file.Length / 1MB, 2)) MB)"
                $copiedCount++
                
                # Generate hash and save to cache
                Write-IntegrityProgress `
                    -Status "Hashing file $currentItem/$fileCount" `
                    -CurrentOperation "Computing MD5: $(Split-Path $file.Name -Leaf)" `
                    -PercentComplete 0
                
                $hash = Get-FileMD5 -FilePath $destFilePath -ProgressCallback {
                    param([long]$BytesRead, [long]$FileSize)
                    $percent = if ($FileSize -gt 0) {
                        [math]::Min(100, ($BytesRead / $FileSize) * 100)
                    } else { 100 }
                    Write-IntegrityProgress `
                        -Status "Hashing file $currentItem/$fileCount" `
                        -CurrentOperation "Computing MD5: $(Split-Path $file.Name -Leaf)" `
                        -PercentComplete $percent
                }
                
                if ($hash) {
                    Save-HashToCache -FilePath $destFilePath -BasePath $dest -Hash $hash -FileSize $file.Length | Out-Null
                }
            }
            else {
                Log-Error "Failed to copy $relativePath : $($copyResult.Error)"
                $errorCount++
            }
        }
    }
    
    $processedBytes += $file.Length
}

Write-Progress -Activity "Cloning drive" -Completed
Write-Progress -Id $integrityProgressId -Activity "Generating verification hashes" -Completed

Log-Message ""
Log-Message "Copy phase complete:"
Log-Message "  Copied: $copiedCount"
Log-Message "  Skipped (already copied): $skippedCount"
Log-Message "  Errors: $errorCount"
Log-Message ""

if ($errorCount -gt 0) {
    Stop-DriveCloner "Copy phase completed with $errorCount errors. Check $errorLog for details."
}

if ($DryRun) {
    Log-Message "Dry run complete. No files were actually copied."
    Write-LogsToDisk
    exit 0
}

# Phase 2: Generate hashes for source files (if not already cached)
Log-Message "=== Phase 2: Generating Source Hashes ==="
$sourceHashCount = 0
$currentItem = 0

foreach ($file in $allFiles) {
    $currentItem++
    $relativePath = Get-RelativePath -Path $file.FullName -BasePath $source
    $displayName = Get-TruncatedText -Text $relativePath -MaxLength 50
    
    # Check if hash already exists
    $cachedHash = Get-HashFromCache -FilePath $file.FullName -BasePath $source -ExpectedFileSize $file.Length
    
    if ($cachedHash -and $cachedHash.IsValid) {
        # Hash already exists, skip
        continue
    }
    
    $sourceHashCount++
    Write-IntegrityProgress `
        -Status "Source hash $currentItem/$fileCount" `
        -CurrentOperation "Computing MD5: $displayName" `
        -PercentComplete (($currentItem / $fileCount) * 100)
    
    $hash = Get-FileMD5 -FilePath $file.FullName -ProgressCallback {
        param([long]$BytesRead, [long]$FileSize)
        $percent = if ($FileSize -gt 0) {
            [math]::Min(100, ($BytesRead / $FileSize) * 100)
        } else { 100 }
        Write-IntegrityProgress `
            -Status "Source hash $currentItem/$fileCount | File $percent%" `
            -CurrentOperation "$displayName" `
            -PercentComplete (($currentItem / $fileCount) * 100)
    }
    
    if ($hash) {
        Save-HashToCache -FilePath $file.FullName -BasePath $source -Hash $hash -FileSize $file.Length | Out-Null
    }
    else {
        Log-Error "Failed to hash source file: $relativePath"
    }
}

Write-Progress -Id $integrityProgressId -Activity "Generating verification hashes" -Completed

Log-Message "Generated $sourceHashCount new source hashes"
Log-Message ""

# Phase 3: Compare hashes
if (-not $SkipHashComparison) {
    Log-Message "=== Phase 3: Verifying Hashes ==="
    $matchCount = 0
    $mismatchCount = 0
    $missingCount = 0
    $currentItem = 0
    
    foreach ($file in $allFiles) {
        $currentItem++
        $relativePath = Get-RelativePath -Path $file.FullName -BasePath $source
        $destFilePath = Join-Path $dest $relativePath
        
        $displayName = Get-TruncatedText -Text $relativePath -MaxLength 50
        Write-IntegrityProgress `
            -Status "Verifying $currentItem/$fileCount" `
            -CurrentOperation $displayName `
            -PercentComplete (($currentItem / $fileCount) * 100)
        
        # Get source hash
        $sourceHash = Get-HashFromCache -FilePath $file.FullName -BasePath $source -ExpectedFileSize $file.Length
        if (-not $sourceHash) {
            Log-Error "Missing source hash: $relativePath"
            Log-Verification "MISSING_SOURCE_HASH | $relativePath"
            $missingCount++
            continue
        }
        
        # Get destination hash
        $destHash = Get-HashFromCache -FilePath $destFilePath -BasePath $dest -ExpectedFileSize $file.Length
        if (-not $destHash) {
            Log-Error "Missing destination hash: $relativePath"
            Log-Verification "MISSING_DEST_HASH | $relativePath"
            $missingCount++
            continue
        }
        
        # Compare hashes
        if ($sourceHash.Hash -eq $destHash.Hash) {
            $matchCount++
            Log-Verification "OK | $relativePath | $($sourceHash.Hash)"
        }
        else {
            $mismatchCount++
            Log-Error "HASH MISMATCH: $relativePath"
            Log-Error "  Source:      $($sourceHash.Hash)"
            Log-Error "  Destination: $($destHash.Hash)"
            Log-Verification "MISMATCH | $relativePath | src=$($sourceHash.Hash) | dst=$($destHash.Hash)"
        }
    }
    
    Write-Progress -Id $integrityProgressId -Activity "Generating verification hashes" -Completed
    
    Log-Message ""
    Log-Message "Verification complete:"
    Log-Message "  Matched: $matchCount"
    Log-Message "  Mismatched: $mismatchCount"
    Log-Message "  Missing: $missingCount"
    Log-Message ""
    
    if ($mismatchCount -gt 0 -or $missingCount -gt 0) {
        Log-Message "⚠️  VERIFICATION FAILED - Drive clone has integrity issues!"
        Log-Message "See $verificationLog for details"
    }
    else {
        Log-Message "✅ VERIFICATION PASSED - Drive clone is complete and verified!"
    }
}
else {
    Log-Message "Skipping hash comparison (SkipHashComparison flag set)"
}

# Save manifest
if (-not $SkipHashComparison) {
    Log-Message ""
    Log-Message "Saving clone manifest..."
    
    $manifestData = @()
    foreach ($file in $allFiles) {
        $relativePath = Get-RelativePath -Path $file.FullName -BasePath $source
        $destFilePath = Join-Path $dest $relativePath
        
        $hash = Get-HashFromCache -FilePath $destFilePath -BasePath $dest -ExpectedFileSize $file.Length
        if ($hash) {
            $manifestData += [PSCustomObject]@{
                RelativePath = $relativePath
                Hash = $hash.Hash
                FileSize = $file.Length
                Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            }
        }
    }
    
    $manifestData | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8
    Log-Message "Manifest saved to $manifestPath"
}

Log-Message ""
Log-Message "=== Drive Cloner Complete ==="
Log-Message "Log file: $driveClonerLog"
if ($errorEntries.Count -gt 0) {
    Log-Message "Error log: $errorLog"
}
if ($verificationEntries.Count -gt 0) {
    Log-Message "Verification log: $verificationLog"
}

Write-LogsToDisk
