param(
    [Parameter(Mandatory=$false)]
    [string]$RootPath = "D:\"
)

# Normalize the path and derive output filenames from it
$root = $RootPath.TrimEnd('\')
if ($root -match '^[A-Z]:$') {
    # It's a drive letter like "D:" - add backslash
    $root = $root + "\"
}

# Derive CSV names from the drive letter or folder name
$driveLetter = if ($root -match '^([A-Z]):') { $matches[1] } else { "media" }
$outItemsCsv   = "${driveLetter}_media_items.csv"
$outSeasonsCsv = "${driveLetter}_media_seasons_detected.csv"

$videoExt = @(".mkv",".mp4",".m4v",".avi",".mov",".wmv",".ts",".m2ts",".webm")
$archiveEndings = @(".tar",".tgz",".tar.gz",".tar.xz",".tar.zst",".zip",".7z",".rar") # include zip/7z if you also bundle that way

# Verbosity knobs
$logEvery = 50
$showPathInProgress = $true

# Create logs folder if it doesn't exist
$logsFolder = "logs"
if (-not (Test-Path $logsFolder)) {
    New-Item -ItemType Directory -Path $logsFolder | Out-Null
}

$ffprobeLog = Join-Path $logsFolder "ffprobe_failures.log"

# Collect errors in memory instead of writing to terminal during execution
$errorLog = New-Object System.Collections.Generic.List[String]

function Get-FfprobeInfo($path) {
    try {
        # -v quiet suppresses error messages to prevent terminal output during progress bar
        $jsonOrError = & ffprobe -v quiet -print_format json -show_streams -show_format "$path" 2>$null | Out-String

        if (-not $jsonOrError) {
            $errorLog.Add("EMPTY OUTPUT :: $path")
            return $null
        }

        $trim = $jsonOrError.Trim()

        # If it doesn't look like JSON, it's an error message
        if (-not $trim.StartsWith("{")) {
            $errorLog.Add(("ERROR :: {0} :: {1}" -f $path, $trim.Replace("`r"," ").Replace("`n"," ")))
            return $null
        }

        $obj = $trim | ConvertFrom-Json

        $dur = 0
        if ($obj.format -and $obj.format.duration) {
            $dur = [int][math]::Round([double]$obj.format.duration)
        }

        $vstream = $obj.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
        $w = 0; $h = 0
        if ($vstream) { $w = [int]$vstream.width; $h = [int]$vstream.height }

        return @{ DurationSec = $dur; Width = $w; Height = $h }
    } catch {
        $errorLog.Add(("EXCEPTION :: {0} :: {1}" -f $path, $_.Exception.Message))
        return $null
    }
}

function EndsWithAny($nameLower, $endings) {
    foreach ($e in $endings) { if ($nameLower.EndsWith($e)) { return $true } }
    return $false
}

function SeasonInfoFromName($text) {
    # Returns @{ Show=""; Season="S01"; Matched=$true } or @{Matched=$false}
    $t = $text

    # Match "S01", "S1"
    $m1 = [regex]::Match($t, '(?i)\bS(?<sn>\d{1,2})\b')
    # Match "Season 1", "Season_01"
    $m2 = [regex]::Match($t, '(?i)\bSeason[\s\._-]*(?<sn>\d{1,2})\b')
    # Match "Series 1" (UK naming)
    $m3 = [regex]::Match($t, '(?i)\bSeries[\s\._-]*(?<sn>\d{1,2})\b')
    # Match "Ep01", "EP6", "Episode 01" (anime/non-standard naming) - treat episode number as implicit season 1
    $m4 = [regex]::Match($t, '(?i)\bEp(?:isode)?[\s\._-]*\d{1,2}\b')
    # Match compact folder names like "TNGS05"
    $m5 = [regex]::Match($t, '(?i)^(?<show>[A-Za-z][A-Za-z0-9]{1,})S(?<sn>\d{1,2})$')

    $sn = $null
    $showFromCompact = $null
    if ($m1.Success) { $sn = $m1.Groups["sn"].Value }
    elseif ($m2.Success) { $sn = $m2.Groups["sn"].Value }
    elseif ($m3.Success) { $sn = $m3.Groups["sn"].Value }
    elseif ($m4.Success) { $sn = "1" }  # Ep## without season info defaults to S01
    elseif ($m5.Success) {
        $sn = $m5.Groups["sn"].Value
        $showFromCompact = $m5.Groups["show"].Value
    }

    if (-not $sn) { return @{ Matched=$false } }

    $season = ("S{0:D2}" -f ([int]$sn))

    # Guess show by removing season tokens & common quality tags
    $show = $t
    if ($showFromCompact) {
        $show = $showFromCompact
    } else {
        $show = [regex]::Replace($show, '(?i)\bS\d{1,2}\b', '')
        $show = [regex]::Replace($show, '(?i)\bSeason[\s\._-]*\d{1,2}\b', '')
        $show = [regex]::Replace($show, '(?i)\bSeries[\s\._-]*\d{1,2}\b', '')
        $show = [regex]::Replace($show, '(?i)\bEp(?:isode)?[\s\._-]*\d{1,2}\b', '')
        $show = [regex]::Replace($show, '(?i)\bComplete\b|\bWEB[-\s]?DL\b|\bBluRay\b|\b1080p\b|\b720p\b|\b2160p\b|\b4K\b|\bHDR\b', '')
    }
    $show = $show -replace '[\._]+', ' '
    $show = $show.Trim(" -_.")

    return @{ Matched=$true; Show=$show; Season=$season }
}

function LooksLikeTvFolderName($folderName) {
    $n = $folderName.ToLower()
    return (
        $n -match '\bseason\b' -or
        $n -match '\bseries\b' -or
        $n -match '\bs\d{1,2}\b' -or
        $n -match '^[a-z0-9]{2,}s\d{1,2}$'
    )
}

function ScoreAndClassifyVideo($fileInfo, $durMin, $w, $h, $inSeasonFolder) {
    $fullPath = $fileInfo.FullName
    $baseName = $fileInfo.BaseName
    $p = $fullPath.ToLower()

    # Path hints
    $pathMovieHint = ($p -match "\\movies\\") -or ($p -match "\\film\\") -or ($p -match "\\blu-?ray\\") -or ($p -match "\\dvds\\")
    $pathTvHint    = ($p -match "\\tv\\") -or ($p -match "\\tv shows\\") -or ($p -match "\\series\\") -or ($p -match "\\season")
    $pathClipHint  = ($p -match "\\clips\\") -or ($p -match "\\obs\\") -or ($p -match "\\recordings\\") -or ($p -match "\\captures\\") -or ($p -match "\\youtube\\") -or ($p -match "\\twitch\\") -or ($p -match "\\gameplay\\") -or ($p -match "\\stream")
    $pathAnimeHint = ($p -match "\\anime\\") -or ($fullPath -match '\[\w+-\w+\]') -or ($p -match "\\hentai\\")  # folder named anime, or [SubGroup] naming, or hentai folder

    # Filename hints
    $isEpisodePattern = ($baseName -match '(?i)\bS\d{1,2}E\d{1,2}\b') -or ($baseName -match '(?i)\b\d{1,2}x\d{1,2}\b') -or ($baseName -match '(?i)\bEp(?:isode)?[\s\._-]*\d{1,2}\b')
    $hasYear = ($baseName -match '(19|20)\d{2}')
    $hasQualityTag = ($baseName -match '(?i)BluRay|Remux|WEB-DL|HDTV')

    # Duration heuristics
    $looksMovieByDur = ($durMin -ge 70)
    $looksTvByDur    = ($durMin -ge 18 -and $durMin -le 70)
    $looksClipByDur  = ($durMin -gt 0 -and $durMin -lt 18)
    $looksShortFilmByDur = ($durMin -ge 30 -and $durMin -lt 70)  # short films: 30-70 min

    # Scores
    $scoreMovie = 0
    $scoreTv = 0
    $scorePersonal = 0

    if ($pathMovieHint) { $scoreMovie += 35 }
    if ($pathTvHint)    { $scoreTv += 35 }
    if ($pathAnimeHint) { $scoreTv += 25 }  # anime folders lean toward TV but not as strongly as TV path
    if ($pathClipHint)  { $scorePersonal += 35 }

    if ($isEpisodePattern) { $scoreTv += 55 }
    if ($inSeasonFolder)   { $scoreTv += 35 }   # big boost if folder screams "season"

    if ($looksMovieByDur) { $scoreMovie += 35 }
    if ($looksTvByDur)    { $scoreTv += 25 }
    if ($looksClipByDur)  { $scorePersonal += 25 }

    # Short film boost: if it has year + quality tag + is in short film duration range, boost as likely short film (not episode)
    if ($looksShortFilmByDur -and $hasYear -and $hasQualityTag) { 
           $scoreMovie += 40  # strong boost for short films with metadata
           if (-not $isEpisodePattern -and -not $pathTvHint) {
              $scoreTv -= 10   # penalize TV score if it has NO episode pattern and is in 30-45 min range
           }
    }

    if ($hasYear -and $looksMovieByDur) { $scoreMovie += 10 }

    # Decide
    $scores = @(
        [pscustomobject]@{ Cat="Movie"; Score=$scoreMovie },
        [pscustomobject]@{ Cat="TV_Episode"; Score=$scoreTv },
        [pscustomobject]@{ Cat="Personal"; Score=$scorePersonal }
    ) | Sort-Object Score -Descending

    $top = $scores[0]
    $second = $scores[1]
    $gap = $top.Score - $second.Score
    $confidence = [math]::Min(100, [math]::Max(0, ($top.Score + $gap)))

    $cat = $top.Cat
    if ($top.Score -lt 40 -or $gap -lt 12) { $cat = "Unknown" }

    return @{ Category=$cat; Confidence=[int]$confidence; ScoreMovie=$scoreMovie; ScoreTV=$scoreTv; ScorePersonal=$scorePersonal }
}

Write-Host "Scanning $root ..." -ForegroundColor Cyan
$start = Get-Date

# 1) Collect PATHS (not objects) to avoid the 'Length=0' trap
$videoPaths = Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $videoExt -contains $_.Extension.ToLower() } |
    Select-Object -ExpandProperty FullName

$archivePaths = Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { EndsWithAny $_.Name.ToLower() $archiveEndings } |
    Select-Object -ExpandProperty FullName

# 2) Detect season folders using folder-name hints + file count
Write-Host "Detecting season folders..." -ForegroundColor DarkCyan
$seasonFolderRows = New-Object System.Collections.Generic.List[Object]
$seasonFolderLookup = @{}

# Group by directory using the PATHS
$byDir = $videoPaths | Group-Object { Split-Path $_ -Parent }

foreach ($g in $byDir) {
    $dir = $g.Name
    $count = $g.Count
    $leaf = Split-Path $dir -Leaf

    # Season folder criteria:
    # - folder name looks like a season (Season/S01/Series) AND has enough videos
    # OR
    # - path contains "\TV\" or "\TV Shows\" AND has enough videos
    $dirLower = $dir.ToLower()
    $folderLooksSeasony = LooksLikeTvFolderName $leaf
    $pathLooksTv = ($dirLower -match "\\tv\\") -or ($dirLower -match "\\tv shows\\") -or ($dirLower -match "\\series\\")
    if ( ($count -ge 4 -and $folderLooksSeasony) -or ($count -ge 6 -and $pathLooksTv) ) {

        $seasonFolderLookup[$dir] = $true

        $seasonGuess = SeasonInfoFromName $leaf
        $showGuess = ""
        $seasonCode = ""
        if ($seasonGuess.Matched) {
            $showGuess = $seasonGuess.Show
            $seasonCode = $seasonGuess.Season
            if (-not $showGuess) {
                # If leaf is "Season 1", show might be parent folder
                $showGuess = Split-Path (Split-Path $dir -Parent) -Leaf
            }
        } else {
            # fallback show guess = parent folder
            $showGuess = Split-Path (Split-Path $dir -Parent) -Leaf
        }

        $seasonFolderRows.Add([pscustomobject]@{
            SeasonFolderPath = $dir
            FolderName       = $leaf
            ShowGuess        = $showGuess
            SeasonGuess      = $seasonCode
            VideoFiles       = $count
        }) | Out-Null
    }
}

Write-Host ("Season folders detected: {0}" -f $seasonFolderRows.Count) -ForegroundColor DarkCyan
Write-Host ("Video files: {0} | Archives: {1}" -f $videoPaths.Count, $archivePaths.Count) -ForegroundColor Cyan

# 3) Process items
$totalItems = $videoPaths.Count + $archivePaths.Count
if ($totalItems -eq 0) {
    Write-Host "No items found under $root (check drive letter / permissions)." -ForegroundColor Yellow
    return
}

$rows = New-Object System.Collections.Generic.List[Object]
$processed = 0
$ffprobeFailed = 0

$movieCount = 0
$tvEpisodeCount = 0
$tvBundleCount = 0
$personalCount = 0
$unknownCount = 0

# Helper to update progress
function Update-ScanProgress($currentName) {
    $pct = [int](($processed / $totalItems) * 100)
    $elapsed = (Get-Date) - $start
    $rate = if ($elapsed.TotalSeconds -gt 0) { $processed / $elapsed.TotalSeconds } else { 0 }
    $etaSec = if ($rate -gt 0) { [int](($totalItems - $processed) / $rate) } else { 0 }
    $eta = (New-TimeSpan -Seconds $etaSec)
    $statusLine = "Processed $processed/$totalItems | Movies:$movieCount TVeps:$tvEpisodeCount TVbundles:$tvBundleCount Personal:$personalCount Unknown:$unknownCount | ffprobe fails:$ffprobeFailed | ETA: {0:hh\:mm\:ss}" -f $eta

    if ($showPathInProgress) {
        # Truncate filename if too long to prevent display corruption
        if ($currentName.Length -gt 60) {
            $displayName = $currentName.Substring(0, 57) + "..."
        } else {
            $displayName = $currentName
        }
        Write-Progress -Activity "Scanning $root media" -Status $statusLine -CurrentOperation $displayName -PercentComplete $pct
    } else {
        Write-Progress -Activity "Scanning $root media" -Status $statusLine -PercentComplete $pct
    }

    if (($processed % $logEvery) -eq 0) {
        Write-Host $statusLine -ForegroundColor DarkGray
    }
}

# --- Videos ---
foreach ($path in $videoPaths) {
    $processed++

    $fi = $null
    try { $fi = Get-Item -LiteralPath $path -ErrorAction Stop } catch { $fi = $null }
    if (-not $fi) { $unknownCount++; Update-ScanProgress (Split-Path $path -Leaf); continue }

    $dir = Split-Path $path -Parent
    $inSeasonFolder = $seasonFolderLookup.ContainsKey($dir)

    $durMin = 0; $w=0; $h=0
    $info = Get-FfprobeInfo $path
    if ($info) {
        $durMin = if ($info.DurationSec -gt 0) { [math]::Round($info.DurationSec/60,2) } else { 0 }
        $w=$info.Width; $h=$info.Height
    } else {
        $ffprobeFailed++
        # Log ffprobe failure - helps identify corrupted files
        $errorLog.Add(("FFPROBE_FAILED :: {0}" -f (Split-Path $path -Leaf)))
    }

    $class = ScoreAndClassifyVideo $fi $durMin $w $h $inSeasonFolder

    switch ($class.Category) {
        "Movie"      { $movieCount++ }
        "TV_Episode" { $tvEpisodeCount++ }
        "Personal"   { $personalCount++ }
        default      { $unknownCount++ }
    }

    $rows.Add([pscustomobject]@{
        ItemType       = "VideoFile"
        FullPath       = $fi.FullName
        FileName       = $fi.Name
        Extension      = $fi.Extension
        SizeGB         = [math]::Round($fi.Length / 1GB, 3)
        DurationMin    = $durMin
        Width          = $w
        Height         = $h
        Created        = $fi.CreationTime
        Modified       = $fi.LastWriteTime
        AutoCategory   = $class.Category
        Confidence     = $class.Confidence
        ScoreMovie     = $class.ScoreMovie
        ScoreTV        = $class.ScoreTV
        ScorePersonal  = $class.ScorePersonal
        InSeasonFolder = $inSeasonFolder
    }) | Out-Null

    Update-ScanProgress $fi.Name
}

# --- Archives (tar/zip/etc.) ---
foreach ($path in $archivePaths) {
    $processed++

    $fi = $null
    try { $fi = Get-Item -LiteralPath $path -ErrorAction Stop } catch { $fi = $null }
    if (-not $fi) { $unknownCount++; Update-ScanProgress (Split-Path $path -Leaf); continue }

    $base = $fi.BaseName
    $sn = SeasonInfoFromName $base

    $cat = "Archive_Unknown"
    $conf = 40
    $show = ""
    $season = ""

    if ($sn.Matched) {
        $cat = "TV_SeasonBundle"
        $conf = 95
        $show = $sn.Show
        $season = $sn.Season
        $tvBundleCount++
    } else {
        # If it lives inside a detected season folder tree, treat as likely TV bundle
        $dirLower = $fi.DirectoryName.ToLower()
        if ($dirLower -match "\\tv\\|\\tv shows\\|\\series\\|\\season") {
            $cat = "TV_SeasonBundle_Possible"
            $conf = 70
            $tvBundleCount++
        } else {
            $unknownCount++
        }
    }

    $rows.Add([pscustomobject]@{
        ItemType       = "Archive"
        FullPath       = $fi.FullName
        FileName       = $fi.Name
        Extension      = $fi.Extension
        SizeGB         = [math]::Round($fi.Length / 1GB, 3)
        DurationMin    = 0
        Width          = 0
        Height         = 0
        Created        = $fi.CreationTime
        Modified       = $fi.LastWriteTime
        AutoCategory   = $cat
        Confidence     = [int]$conf
        ShowGuess      = $show
        SeasonGuess    = $season
        InSeasonFolder = $false
    }) | Out-Null

    Update-ScanProgress $fi.Name
}

Write-Progress -Activity "Scanning $root media" -Completed

$rows | Export-Csv $outItemsCsv -NoTypeInformation
$seasonFolderRows | Export-Csv $outSeasonsCsv -NoTypeInformation

# Write error log to file
if ($errorLog.Count -gt 0) {
    $errorLog | Set-Content $ffprobeLog
}

$totalTime = (Get-Date) - $start
Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ("Wrote {0} rows -> {1}" -f $rows.Count, $outItemsCsv) -ForegroundColor Green
Write-Host ("Wrote {0} season folders -> {1}" -f $seasonFolderRows.Count, $outSeasonsCsv) -ForegroundColor Green
Write-Host ("Totals: Movies={0} | TV_Episodes={1} | TV_Bundles={2} | Personal={3} | Unknown={4}" -f $movieCount,$tvEpisodeCount,$tvBundleCount,$personalCount,$unknownCount)
Write-Host ("ffprobe failures: {0}" -f $ffprobeFailed)
Write-Host ("Elapsed: {0:hh\:mm\:ss}" -f $totalTime)

# Display errors at the end, after progress bar is cleared
if ($errorLog.Count -gt 0) {
    Write-Host ""
    Write-Host "=== ERRORS (also saved to $ffprobeLog) ===" -ForegroundColor Yellow
    foreach ($err in $errorLog) {
        Write-Host $err -ForegroundColor Yellow
    }
    Write-Host "=== END ERRORS ===" -ForegroundColor Yellow
}

# Signal completion with visual marker and beep
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "         SCAN COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

# Play a completion sound (three ascending tones)
[System.Console]::Beep(800, 100)   # Low tone
Start-Sleep -Milliseconds 150
[System.Console]::Beep(1000, 100)  # Mid tone
Start-Sleep -Milliseconds 150
[System.Console]::Beep(1200, 200)  # High tone (longer)