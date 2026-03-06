param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [Parameter(Mandatory = $false)]
    [string[]]$Extensions = @('.mkv', '.mp4', '.m4v', '.mov', '.avi', '.ts', '.m2ts', '.webm'),

    [Parameter(Mandatory = $false)]
    [switch]$DryRun = $false,

    [Parameter(Mandatory = $false)]
    [switch]$KeepBackup = $false,

    [Parameter(Mandatory = $false)]
    [switch]$AllowWithoutEnglish = $false
)

$root = $RootPath.TrimEnd('\\')
if ($root -match '^[A-Z]:$') {
    $root = $root + '\\'
}

if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Error "Root path does not exist or is not a directory: $root"
    exit 1
}

$ffprobeCommand = Get-Command ffprobe -ErrorAction SilentlyContinue
if (-not $ffprobeCommand) {
    Write-Error "ffprobe is required but was not found in PATH. Install FFmpeg and verify with: ffprobe -version"
    exit 1
}

$ffmpegCommand = Get-Command ffmpeg -ErrorAction SilentlyContinue
if (-not $ffmpegCommand) {
    Write-Error "ffmpeg is required but was not found in PATH. Install FFmpeg and verify with: ffmpeg -version"
    exit 1
}

$logsFolder = 'logs'
if (-not (Test-Path -LiteralPath $logsFolder)) {
    New-Item -ItemType Directory -Path $logsFolder | Out-Null
}

$runTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$mainLogPath = Join-Path $logsFolder "audio_normalizer_$runTimestamp.log"
$errorLogPath = Join-Path $logsFolder "audio_normalizer_errors_$runTimestamp.log"

$logEntries = New-Object System.Collections.Generic.List[string]
$errorEntries = New-Object System.Collections.Generic.List[string]

$germanLanguageCodes = @('de', 'deu', 'ger')
$germanTitleHints = @('german', 'deutsch')
$englishLanguageCodes = @('en', 'eng')
$englishTitleHints = @('english', 'englisch')

function Write-LogsToDisk {
    if ($logEntries.Count -gt 0) {
        $logEntries | Out-File -FilePath $mainLogPath -Encoding UTF8
    }
    if ($errorEntries.Count -gt 0) {
        $errorEntries | Out-File -FilePath $errorLogPath -Encoding UTF8
    }
}

function Log-Message {
    param([string]$Message)

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] $Message"
    $logEntries.Add($entry)
    Write-Host $entry
}

function Log-Error {
    param([string]$Message)

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] ERROR: $Message"
    $errorEntries.Add($entry)
    Write-Host $entry -ForegroundColor Red
}

function Add-CounterValue {
    param(
        [hashtable]$Counter,
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        $Key = '(unspecified)'
    }

    if ($Counter.ContainsKey($Key)) {
        $Counter[$Key] = [int]$Counter[$Key] + 1
    }
    else {
        $Counter[$Key] = 1
    }
}

function Get-StreamTagValue {
    param(
        $Stream,
        [string]$TagName
    )

    if ($null -eq $Stream -or $null -eq $Stream.tags) {
        return ''
    }

    $property = $Stream.tags.PSObject.Properties | Where-Object { $_.Name -ieq $TagName } | Select-Object -First 1
    if ($property) {
        return [string]$property.Value
    }

    return ''
}

function Test-LanguageCodeMatch {
    param(
        [string]$Value,
        [string[]]$Candidates
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $normalized = $Value.Trim().ToLowerInvariant()

    foreach ($candidate in $Candidates) {
        $candidateNorm = $candidate.ToLowerInvariant()
        if ($normalized -eq $candidateNorm) {
            return $true
        }
        if ($normalized.StartsWith($candidateNorm + '-')) {
            return $true
        }
    }

    return $false
}

function Test-TitleHint {
    param(
        [string]$Value,
        [string[]]$Hints
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $normalized = $Value.Trim().ToLowerInvariant()

    foreach ($hint in $Hints) {
        $escapedHint = [regex]::Escape($hint.ToLowerInvariant())
        if ($normalized -match "(^|[^a-z])$escapedHint([^a-z]|$)") {
            return $true
        }
    }

    return $false
}

function Get-ProbeInfo {
    param([string]$FilePath)

    try {
        $probeArgs = @(
            '-v', 'quiet',
            '-print_format', 'json',
            '-show_streams',
            '--', $FilePath
        )

        $jsonOutput = (& ffprobe @probeArgs 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($jsonOutput)) {
            return $null
        }

        return ($jsonOutput | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Build-AudioNormalizationPlan {
    param(
        $ProbeInfo,
        [switch]$AllowNoEnglishTrack = $false
    )

    if ($null -eq $ProbeInfo -or $null -eq $ProbeInfo.streams) {
        return [PSCustomObject]@{
            ShouldProcess = $false
            Reason = 'ffprobe returned no stream data'
        }
    }

    $allStreams = @($ProbeInfo.streams | Sort-Object { [int]$_.index })
    $audioTracks = @()
    $audioOrdinal = 0

    foreach ($stream in $allStreams) {
        if ($stream.codec_type -ne 'audio') {
            continue
        }

        $languageTag = Get-StreamTagValue -Stream $stream -TagName 'language'
        $titleTag = Get-StreamTagValue -Stream $stream -TagName 'title'

        $isGerman = (Test-LanguageCodeMatch -Value $languageTag -Candidates $germanLanguageCodes) -or
            (Test-TitleHint -Value $titleTag -Hints $germanTitleHints)

        $isEnglish = (Test-LanguageCodeMatch -Value $languageTag -Candidates $englishLanguageCodes) -or
            (Test-TitleHint -Value $titleTag -Hints $englishTitleHints)

        $isDefault = $false
        if ($null -ne $stream.disposition -and $null -ne $stream.disposition.default) {
            $isDefault = ([int]$stream.disposition.default -eq 1)
        }

        $audioTracks += [PSCustomObject]@{
            StreamIndex = [int]$stream.index
            AudioIndex = $audioOrdinal
            Language = $languageTag
            Title = $titleTag
            IsGerman = $isGerman
            IsEnglish = $isEnglish
            IsDefault = $isDefault
        }

        $audioOrdinal++
    }

    if ($audioTracks.Count -eq 0) {
        return [PSCustomObject]@{
            ShouldProcess = $false
            Reason = 'no audio streams found'
        }
    }

    $tracksToRemove = @($audioTracks | Where-Object { $_.IsGerman })
    $tracksToKeep = @($audioTracks | Where-Object { -not $_.IsGerman })

    if ($tracksToKeep.Count -eq 0) {
        return [PSCustomObject]@{
            ShouldProcess = $false
            Reason = 'all audio tracks appear to be German; skipping to avoid silent output'
            AudioTracks = $audioTracks
        }
    }

    $englishCandidates = @($tracksToKeep | Where-Object { $_.IsEnglish })
    if ($englishCandidates.Count -eq 0 -and -not $AllowNoEnglishTrack) {
        return [PSCustomObject]@{
            ShouldProcess = $false
            Reason = 'no English track detected after removing German tracks'
            AudioTracks = $audioTracks
        }
    }

    $targetDefaultTrack = $null
    if ($englishCandidates.Count -gt 0) {
        $targetDefaultTrack = $englishCandidates | Where-Object { $_.IsDefault } | Select-Object -First 1
        if (-not $targetDefaultTrack) {
            $targetDefaultTrack = $englishCandidates[0]
        }
    }
    else {
        $targetDefaultTrack = $tracksToKeep[0]
    }

    $defaultTracks = @($audioTracks | Where-Object { $_.IsDefault })
    $defaultNeedsUpdate = $true
    if ($defaultTracks.Count -eq 1 -and $defaultTracks[0].StreamIndex -eq $targetDefaultTrack.StreamIndex) {
        $defaultNeedsUpdate = $false
    }

    $shouldProcess = ($tracksToRemove.Count -gt 0) -or $defaultNeedsUpdate
    if (-not $shouldProcess) {
        return [PSCustomObject]@{
            ShouldProcess = $false
            Reason = 'already normalized (no German track and default audio already correct)'
            AudioTracks = $audioTracks
        }
    }

    $targetOutputAudioIndex = -1
    for ($i = 0; $i -lt $tracksToKeep.Count; $i++) {
        if ($tracksToKeep[$i].StreamIndex -eq $targetDefaultTrack.StreamIndex) {
            $targetOutputAudioIndex = $i
            break
        }
    }

    if ($targetOutputAudioIndex -lt 0) {
        return [PSCustomObject]@{
            ShouldProcess = $false
            Reason = 'failed to determine output audio index for target default track'
            AudioTracks = $audioTracks
        }
    }

    $targetLanguage = if ([string]::IsNullOrWhiteSpace($targetDefaultTrack.Language)) { '(unknown)' } else { $targetDefaultTrack.Language }

    return [PSCustomObject]@{
        ShouldProcess = $true
        Reason = 'normalization needed'
        AudioTracks = $audioTracks
        TracksToRemove = $tracksToRemove
        TracksToKeep = $tracksToKeep
        TargetDefaultTrack = $targetDefaultTrack
        TargetDefaultOutputAudioIndex = $targetOutputAudioIndex
        TargetDefaultLanguage = $targetLanguage
    }
}

function Invoke-AudioNormalization {
    param(
        [string]$FilePath,
        [PSCustomObject]$Plan,
        [switch]$DryRunMode = $false,
        [switch]$KeepBackupMode = $false
    )

    $fileName = Split-Path $FilePath -Leaf
    $tracksToRemoveSummary = @($Plan.TracksToRemove | ForEach-Object {
        "stream:$($_.StreamIndex) lang:$($_.Language)"
    }) -join '; '

    if ([string]::IsNullOrWhiteSpace($tracksToRemoveSummary)) {
        $tracksToRemoveSummary = '(none)'
    }

    $actionSummary = "remove German tracks [$tracksToRemoveSummary], set default audio to output a:$($Plan.TargetDefaultOutputAudioIndex) lang:$($Plan.TargetDefaultLanguage)"

    if ($DryRunMode) {
        return [PSCustomObject]@{
            Success = $true
            Changed = $false
            DryRun = $true
            FileName = $fileName
            Detail = $actionSummary
        }
    }

    # Use .NET path APIs for compatibility with Windows PowerShell 5.1.
    $directory = [System.IO.Path]::GetDirectoryName($FilePath)
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = Split-Path -Path $FilePath -Parent
    }

    if ([string]::IsNullOrWhiteSpace($directory)) {
        return [PSCustomObject]@{
            Success = $false
            Changed = $false
            DryRun = $false
            FileName = $fileName
            Detail = "failed to resolve parent directory for '$fileName'"
        }
    }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $extension = [System.IO.Path]::GetExtension($FilePath)
    $tempFilePath = Join-Path $directory ("{0}.audiofix_tmp_{1}{2}" -f $baseName, ([guid]::NewGuid().ToString('N').Substring(0, 8)), $extension)

    $ffmpegArgs = @(
        '-hide_banner',
        '-loglevel', 'error',
        '-y',
        '-i', $FilePath,
        '-map', '0'
    )

    foreach ($track in $Plan.TracksToRemove) {
        $ffmpegArgs += @('-map', "-0:$($track.StreamIndex)")
    }

    $ffmpegArgs += @(
        '-map_metadata', '0',
        '-map_chapters', '0',
        '-c', 'copy'
    )

    for ($audioOutIndex = 0; $audioOutIndex -lt $Plan.TracksToKeep.Count; $audioOutIndex++) {
        $ffmpegArgs += @("-disposition:a:$audioOutIndex", '0')
    }

    $ffmpegArgs += @("-disposition:a:$($Plan.TargetDefaultOutputAudioIndex)", 'default')
    $ffmpegArgs += $tempFilePath

    $ffmpegOutput = ''
    $ffmpegExitCode = 0

    try {
        $ffmpegOutput = (& ffmpeg @ffmpegArgs 2>&1 | Out-String)
        $ffmpegExitCode = $LASTEXITCODE
    }
    catch {
        $ffmpegOutput = $_.Exception.Message
        $ffmpegExitCode = 1
    }

    if ($ffmpegExitCode -ne 0 -or -not (Test-Path -LiteralPath $tempFilePath -PathType Leaf)) {
        if (Test-Path -LiteralPath $tempFilePath -PathType Leaf) {
            Remove-Item -LiteralPath $tempFilePath -Force -ErrorAction SilentlyContinue
        }

        $failureMessage = "ffmpeg failed for '$fileName'. Exit code: $ffmpegExitCode"
        if (-not [string]::IsNullOrWhiteSpace($ffmpegOutput)) {
            $singleLineOutput = $ffmpegOutput.Replace("`r", ' ').Replace("`n", ' ').Trim()
            $failureMessage = "$failureMessage | $singleLineOutput"
        }

        return [PSCustomObject]@{
            Success = $false
            Changed = $false
            DryRun = $false
            FileName = $fileName
            Detail = $failureMessage
        }
    }

    try {
        if ($KeepBackupMode) {
            $backupPath = $FilePath + '.audiofix.bak'
            [System.IO.File]::Replace($tempFilePath, $FilePath, $backupPath, $true)
        }
        else {
            $transientBackupPath = $FilePath + '.audiofix.swap'
            if (Test-Path -LiteralPath $transientBackupPath -PathType Leaf) {
                Remove-Item -LiteralPath $transientBackupPath -Force -ErrorAction SilentlyContinue
            }

            [System.IO.File]::Replace($tempFilePath, $FilePath, $transientBackupPath, $true)

            if (Test-Path -LiteralPath $transientBackupPath -PathType Leaf) {
                Remove-Item -LiteralPath $transientBackupPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        if (Test-Path -LiteralPath $tempFilePath -PathType Leaf) {
            Remove-Item -LiteralPath $tempFilePath -Force -ErrorAction SilentlyContinue
        }

        return [PSCustomObject]@{
            Success = $false
            Changed = $false
            DryRun = $false
            FileName = $fileName
            Detail = "failed to replace original file '$fileName' with normalized output: $($_.Exception.Message)"
        }
    }

    return [PSCustomObject]@{
        Success = $true
        Changed = $true
        DryRun = $false
        FileName = $fileName
        Detail = $actionSummary
    }
}

$normalizedExtensions = @{}
foreach ($extension in $Extensions) {
    if ([string]::IsNullOrWhiteSpace($extension)) {
        continue
    }

    $fixed = $extension.Trim().ToLowerInvariant()
    if (-not $fixed.StartsWith('.')) {
        $fixed = '.' + $fixed
    }

    $normalizedExtensions[$fixed] = $true
}

if ($normalizedExtensions.Count -eq 0) {
    Write-Error 'No valid file extensions were provided.'
    exit 1
}

$mediaFiles = Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
    $ext = $_.Extension.ToLowerInvariant()
    $normalizedExtensions.ContainsKey($ext)
}

Log-Message '=== Audio Normalizer Started ==='
Log-Message "Root path: $root"
Log-Message "DryRun: $DryRun"
Log-Message "KeepBackup: $KeepBackup"
Log-Message "AllowWithoutEnglish: $AllowWithoutEnglish"
Log-Message "Extensions: $($normalizedExtensions.Keys -join ', ')"
Log-Message "Candidate files found: $($mediaFiles.Count)"

if ($mediaFiles.Count -eq 0) {
    Log-Message 'No matching media files were found.'
    Write-LogsToDisk
    exit 0
}

$processed = 0
$changed = 0
$wouldChange = 0
$skipped = 0
$failed = 0
$skipReasons = @{}

foreach ($mediaFile in $mediaFiles) {
    $processed++
    $percentComplete = [int][math]::Round(($processed / $mediaFiles.Count) * 100)

    Write-Progress -Activity 'Normalizing audio tracks' `
        -Status "Processing $processed/$($mediaFiles.Count)" `
        -CurrentOperation $mediaFile.Name `
        -PercentComplete $percentComplete

    $probeInfo = Get-ProbeInfo -FilePath $mediaFile.FullName
    if (-not $probeInfo) {
        $failed++
        Log-Error "ffprobe failed or returned invalid data for '$($mediaFile.FullName)'"
        continue
    }

    $plan = Build-AudioNormalizationPlan -ProbeInfo $probeInfo -AllowNoEnglishTrack:$AllowWithoutEnglish
    if (-not $plan.ShouldProcess) {
        $skipped++
        Add-CounterValue -Counter $skipReasons -Key $plan.Reason
        continue
    }

    $result = Invoke-AudioNormalization -FilePath $mediaFile.FullName -Plan $plan -DryRunMode:$DryRun -KeepBackupMode:$KeepBackup
    if (-not $result.Success) {
        $failed++
        Log-Error $result.Detail
        continue
    }

    if ($DryRun) {
        $wouldChange++
        Log-Message "[DRY RUN] $($mediaFile.FullName) => $($result.Detail)"
    }
    else {
        $changed++
        Log-Message "[UPDATED] $($mediaFile.FullName) => $($result.Detail)"
    }
}

Write-Progress -Activity 'Normalizing audio tracks' -Completed

Log-Message '=== Audio Normalizer Summary ==='
Log-Message "Processed: $processed"
if ($DryRun) {
    Log-Message "Would change: $wouldChange"
}
else {
    Log-Message "Changed: $changed"
}
Log-Message "Skipped: $skipped"
Log-Message "Failed: $failed"

if ($skipReasons.Count -gt 0) {
    Log-Message 'Skip reasons:'
    foreach ($reason in ($skipReasons.Keys | Sort-Object)) {
        $count = $skipReasons[$reason]
        $message = "  - ${reason}: ${count}"
        Log-Message $message
    }
}

Log-Message "Log file: $mainLogPath"
if ($errorEntries.Count -gt 0) {
    Log-Message "Error log: $errorLogPath"
}

Write-LogsToDisk

if ($failed -gt 0) {
    exit 1
}

exit 0
