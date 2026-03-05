$root = "X:\"
$outCsv = "X_media_enriched.csv"

# Video extensions to consider
$videoExt = @(".mkv",".mp4",".m4v",".avi",".mov",".wmv",".ts",".m2ts",".webm")

# Verbosity knobs
$logEvery = 25          # Write-Host every N files processed
$showPathInProgress = $true  # show current filename in the progress bar

function Get-FfprobeInfo($path) {
    # Returns @{ DurationSec = int; Width=int; Height=int } or $null
    try {
        $json = & ffprobe -v quiet -print_format json -show_streams -show_format --% "$path" | Out-String
        if (-not $json) { return $null }
        $obj = $json | ConvertFrom-Json

        $dur = 0
        if ($obj.format -and $obj.format.duration) {
            $dur = [int][math]::Round([double]$obj.format.duration)
        }

        $vstream = $obj.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
        $w = 0; $h = 0
        if ($vstream) { $w = [int]$vstream.width; $h = [int]$vstream.height }

        return @{ DurationSec = $dur; Width = $w; Height = $h }
    } catch {
        return $null
    }
}

function Score-And-Classify($fullPath, $name, $dir, $durMin, $w, $h) {
    $p = $fullPath.ToLower()

    # Hints from path
    $pathMovieHint = ($p -match "\\movies\\") -or ($p -match "\\film\\") -or ($p -match "\\blu-ray\\") -or ($p -match "\\dvds\\")
    $pathTvHint    = ($p -match "\\tv\\") -or ($p -match "\\tv shows\\") -or ($p -match "\\series\\") -or ($p -match "\\season")
    $pathClipHint  = ($p -match "\\clips\\") -or ($p -match "\\obs\\") -or ($p -match "\\recordings\\") -or ($p -match "\\captures\\") -or ($p -match "\\youtube\\") -or ($p -match "\\twitch\\") -or ($p -match "\\gameplay\\") -or ($p -match "\\stream")

    # Hints from filename
    $isSxxEyy = ($name -match "(?i)\bS\d{1,2}E\d{1,2}\b") -or ($name -match "(?i)\b\d{1,2}x\d{1,2}\b")
    $hasEpisodeWords = ($name -match "(?i)\bepisode\b|\bep\.?\b")
    $hasYear = ($name -match "(19|20)\d{2}")

    # Duration heuristics
    $looksMovieByDur = ($durMin -ge 70)
    $looksTvByDur    = ($durMin -ge 18 -and $durMin -le 70)
    $looksClipByDur  = ($durMin -gt 0 -and $durMin -lt 18)

    # Resolution heuristic
    $looksCaptured = ($w -eq 1920 -and $h -eq 1080) -or ($w -eq 2560 -and $h -eq 1440) -or ($w -eq 3840 -and $h -eq 2160)

    $scoreMovie = 0
    $scoreTv = 0
    $scoreClip = 0

    if ($pathMovieHint) { $scoreMovie += 35 }
    if ($pathTvHint)    { $scoreTv += 35 }
    if ($pathClipHint)  { $scoreClip += 35 }

    if ($isSxxEyy)      { $scoreTv += 45 }
    if ($hasEpisodeWords) { $scoreTv += 15 }

    if ($looksMovieByDur) { $scoreMovie += 35 }
    if ($looksTvByDur)    { $scoreTv += 25 }
    if ($looksClipByDur)  { $scoreClip += 25 }

    if ($hasYear -and $looksMovieByDur) { $scoreMovie += 10 }

    if ($pathClipHint -and $looksCaptured -and $looksClipByDur) { $scoreClip += 15 }

    $scores = @(
        [pscustomobject]@{ Cat="Movie";    Score=$scoreMovie },
        [pscustomobject]@{ Cat="TV";       Score=$scoreTv },
        [pscustomobject]@{ Cat="Personal"; Score=$scoreClip }
    ) | Sort-Object Score -Descending

    $top = $scores[0]
    $second = $scores[1]

    $gap = $top.Score - $second.Score
    $confidence = [math]::Min(100, [math]::Max(0, ($top.Score + $gap)))

    $category = $top.Cat
    if ($top.Score -lt 35 -or $gap -lt 15) { $category = "Unknown" }

    return @{ Category=$category; Confidence=[int]$confidence; ScoreMovie=$scoreMovie; ScoreTV=$scoreTv; ScorePersonal=$scoreClip }
}

# --- PRE-SCAN so we can show accurate progress % ---
Write-Host "Scanning $root for video files..." -ForegroundColor Cyan
$start = Get-Date

$files = Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $videoExt -contains $_.Extension.ToLower() }

$total = ($files | Measure-Object).Count
if ($total -eq 0) {
    Write-Host "No matching video files found under $root" -ForegroundColor Yellow
    return
}

Write-Host "Found $total video files. Starting ffprobe + classification..." -ForegroundColor Cyan

# --- Processing ---
$rows = New-Object System.Collections.Generic.List[Object]

$processed = 0
$ffprobeFailed = 0

$movieCount = 0
$tvCount = 0
$personalCount = 0
$unknownCount = 0

foreach ($f in $files) {
    $processed++

    $info = Get-FfprobeInfo $f.FullName
    $durSec = 0; $w=0; $h=0
    if ($info) {
        $durSec = $info.DurationSec; $w=$info.Width; $h=$info.Height
    } else {
        $ffprobeFailed++
    }

    $durMin = if ($durSec -gt 0) { [math]::Round($durSec/60,2) } else { 0 }

    $class = Score-And-Classify $f.FullName $f.BaseName $f.DirectoryName $durMin $w $h

    switch ($class.Category) {
        "Movie"    { $movieCount++ }
        "TV"       { $tvCount++ }
        "Personal" { $personalCount++ }
        "Unknown"  { $unknownCount++ }
    }

    $rows.Add([pscustomobject]@{
        FullPath       = $f.FullName
        FileName       = $f.Name
        Extension      = $f.Extension
        SizeGB         = [math]::Round($f.Length / 1GB, 3)
        DurationMin    = $durMin
        Width          = $w
        Height         = $h
        Created        = $f.CreationTime
        Modified       = $f.LastWriteTime
        AutoCategory   = $class.Category
        Confidence     = $class.Confidence
        ScoreMovie     = $class.ScoreMovie
        ScoreTV        = $class.ScoreTV
        ScorePersonal  = $class.ScorePersonal
    })

    # --- Progress display ---
    $pct = [int](($processed / $total) * 100)

    $elapsed = (Get-Date) - $start
    $rate = if ($elapsed.TotalSeconds -gt 0) { $processed / $elapsed.TotalSeconds } else { 0 }
    $etaSec = if ($rate -gt 0) { [int](($total - $processed) / $rate) } else { 0 }
    $eta = (New-TimeSpan -Seconds $etaSec)

    $statusLine = "Processed $processed / $total | Movies:$movieCount TV:$tvCount Personal:$personalCount Unknown:$unknownCount | ffprobe fails:$ffprobeFailed | ETA: {0:hh\:mm\:ss}" -f $eta

    $activity = "Classifying media files"
    if ($showPathInProgress) {
        $current = $f.Name
        Write-Progress -Activity $activity -Status "$statusLine`n$current" -PercentComplete $pct
    } else {
        Write-Progress -Activity $activity -Status $statusLine -PercentComplete $pct
    }

    # --- Occasional log line ---
    if (($processed % $logEvery) -eq 0) {
        Write-Host $statusLine -ForegroundColor DarkGray
    }
}

Write-Progress -Activity "Classifying media files" -Completed

# --- Export + summary ---
$rows | Export-Csv $outCsv -NoTypeInformation

$totalTime = (Get-Date) - $start
Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ("Wrote {0} with {1} rows" -f $outCsv, $rows.Count) -ForegroundColor Green
Write-Host ("Totals: Movies={0} | TV={1} | Personal={2} | Unknown={3}" -f $movieCount, $tvCount, $personalCount, $unknownCount)
Write-Host ("ffprobe failures: {0}" -f $ffprobeFailed)
Write-Host ("Elapsed: {0:hh\:mm\:ss}" -f $totalTime)