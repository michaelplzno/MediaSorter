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
$outGroupsCsv  = "${driveLetter}_media_groups.csv"
$outDupesCsv   = "${driveLetter}_media_duplicates.csv"

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

# Noise words to remove from show names (case-insensitive)
$script:noiseWords = @(
    "GERMAN", "DUTCH", "FRENCH", "SPANISH", "ITALIAN", "JAPANESE", "RUSSIAN", "POLISH", "PORTUGUESE",
    "BluRay", "BDRip", "BRRip", "Remux", "WEB-DL", "WEBRip", "HDTV", "DVDRip", "WebHD",
    "1080p", "720p", "2160p", "4K", "480p", "576p",
    "x264", "x265", "h264", "h265", "HEVC", "AVC", "XviD", "DivX",
    "AAC", "AC3", "DTS", "TrueHD", "Atmos", "EAC3", "DD5", "DDP5",
    "iNTERNAL", "PROPER", "REPACK", "LIMITED", "UNRATED", "EXTENDED", "DIRECTORS", "CUT",
    "COMPLETE", "FULL", "SEASON", "SERIES",
    "MULTi", "DUAL", "SUBBED", "DUBBED", "DL"
)

# Normalize all delimiters to spaces: . _ - and space all become space
function Normalize-Delimiters($text) {
    return $text -replace '[\._\-]+', ' '
}

# Remove noise words from text (case-insensitive)
function Remove-NoiseWords($text) {
    $cleaned = $text
    foreach ($noise in $script:noiseWords) {
        # Use word boundaries to avoid partial matches
        $cleaned = $cleaned -replace "(?i)\b$([regex]::Escape($noise))\b", ""
    }
    return $cleaned
}

function SeasonInfoFromName($text) {
    # Returns @{ Show=""; Season="S01"; Matched=$true } or @{Matched=$false}
    $t = $text

    # Match "S01", "S1", "S39" (SXX where XX < 40)
    $m1 = [regex]::Match($t, '(?i)\bS(?<sn>\d{1,2})\b')
    # Match "Season 1", "Season_01"
    $m2 = [regex]::Match($t, '(?i)\bSeason[\s\._-]*(?<sn>\d{1,2})\b')
    # Match "Series 1" (UK naming)
    $m3 = [regex]::Match($t, '(?i)\bSeries[\s\._-]*(?<sn>\d{1,2})\b')
    # Match "Ep01", "EP6", "Episode 01" (anime/non-standard naming) - treat episode number as implicit season 1
    $m4 = [regex]::Match($t, '(?i)\bEp(?:isode)?[\s\._-]*\d{1,2}\b')
    # Match compact folder names like "TNGS05"
    $m5 = [regex]::Match($t, '(?i)^(?<show>[A-Za-z][A-Za-z0-9]{1,})S(?<sn>\d{1,2})$')
    # Match year as delimiter (19XX or 20XX)
    $mYear = [regex]::Match($t, '(?i)\b(?<year>(19|20)\d{2})\b')

    $sn = $null
    $showFromCompact = $null
    $usedYearAsDelimiter = $false
    
    # Check if SXX match is valid (XX < 40)
    if ($m1.Success) { 
        $snVal = [int]$m1.Groups["sn"].Value
        if ($snVal -lt 40) {
            $sn = $m1.Groups["sn"].Value 
        }
    }
    
    if (-not $sn) {
        if ($m2.Success) { $sn = $m2.Groups["sn"].Value }
        elseif ($m3.Success) { $sn = $m3.Groups["sn"].Value }
        elseif ($m4.Success) { $sn = "1" }  # Ep## without season info defaults to S01
        elseif ($m5.Success) {
            $snVal = [int]$m5.Groups["sn"].Value
            if ($snVal -lt 40) {
                $sn = $m5.Groups["sn"].Value
                $showFromCompact = $m5.Groups["show"].Value
            }
        }
    }

    if (-not $sn) { return @{ Matched=$false } }

    $season = ("S{0:D2}" -f ([int]$sn))

    # Extract show name: Everything BEFORE the season pattern (or year) is the name
    # Pattern: Show.Name.S01.extra.stuff → extract "Show.Name"
    # Pattern: Show.Name.2020.extra.stuff → extract "Show.Name"
    $show = $t
    if ($showFromCompact) {
        $show = $showFromCompact
    } else {
        # Find the position of the season marker and take everything before it
        if ($m1.Success) {
            $show = $t.Substring(0, $m1.Index)
        }
        elseif ($m2.Success) {
            $show = $t.Substring(0, $m2.Index)
        }
        elseif ($m3.Success) {
            $show = $t.Substring(0, $m3.Index)
        }
        elseif ($m4.Success) {
            $show = $t.Substring(0, $m4.Index)
        }
        
        # If show is empty after extraction, or if we have a year, use year as delimiter
        if ([string]::IsNullOrWhiteSpace($show) -or $mYear.Success) {
            if ($mYear.Success) {
                $show = $t.Substring(0, $mYear.Index)
                $usedYearAsDelimiter = $true
            }
        }
    }
    
    # Normalize delimiters (. _ - → space)
    $show = Normalize-Delimiters $show
    
    # Remove noise words
    $show = Remove-NoiseWords $show
    
    # Clean up extra spaces
    $show = $show -replace '\s+', ' '
    $show = $show.Trim()

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

function EpisodeInfoFromName($text) {
    # Returns @{ Show=""; Season="S01"; Episode="E05"; Matched=$true } or @{Matched=$false}
    $t = $text

    # Match "S01E05", "S1E5", etc. (SXX where XX < 40)
    $m1 = [regex]::Match($t, '(?i)\bS(?<sn>\d{1,2})E(?<ep>\d{1,2})\b')
    # Match "1x05", "01x05", etc.
    $m2 = [regex]::Match($t, '(?i)\b(?<sn>\d{1,2})x(?<ep>\d{1,2})\b')
    # Match "Episode 05", "Ep05", "EP_05"
    $m3 = [regex]::Match($t, '(?i)\bEp(?:isode)?[\s\._-]*(?<ep>\d{1,2})\b')
    # Match standalone "E05", "E12" (any EXX)
    $m4 = [regex]::Match($t, '(?i)\bE(?<ep>\d{1,2})\b')
    # Match year as delimiter (19XX or 20XX)
    $mYear = [regex]::Match($t, '(?i)\b(?<year>(19|20)\d{2})\b')

    $sn = $null
    $ep = $null
    $usedYearAsDelimiter = $false

    # Check if SXX match is valid (XX < 40)
    if ($m1.Success) {
        $snVal = [int]$m1.Groups["sn"].Value
        if ($snVal -lt 40) {
            $sn = $m1.Groups["sn"].Value 
            $ep = $m1.Groups["ep"].Value
        }
    }
    
    if (-not $ep) {
        if ($m2.Success) { 
            $sn = $m2.Groups["sn"].Value 
            $ep = $m2.Groups["ep"].Value
        }
        elseif ($m3.Success) { 
            $sn = "1"  # Default to season 1 if not specified
            $ep = $m3.Groups["ep"].Value
        }
        elseif ($m4.Success) {
            $sn = "1"  # Standalone EXX defaults to season 1
            $ep = $m4.Groups["ep"].Value
        }
    }

    if (-not $ep) { return @{ Matched=$false } }

    $season = ("S{0:D2}" -f ([int]$sn))
    $episode = ("E{0:D2}" -f ([int]$ep))

    # Extract show name: Everything BEFORE the episode pattern (or year) is the name
    # Pattern: Show.Name.S01E01.extra.stuff → extract "Show.Name"
    # Pattern: Show.Name.2020.extra.stuff → extract "Show.Name"
    $show = $t
    
    # Find the position of the episode marker and take everything before it
    $cutIndex = -1
    if ($m1.Success) {
        $cutIndex = $m1.Index
    }
    elseif ($m2.Success) {
        $cutIndex = $m2.Index
    }
    elseif ($m3.Success) {
        $cutIndex = $m3.Index
    }
    elseif ($m4.Success) {
        $cutIndex = $m4.Index
    }
    
    # Also check for year as delimiter - use whichever comes first
    if ($mYear.Success) {
        if ($cutIndex -lt 0 -or $mYear.Index -lt $cutIndex) {
            $cutIndex = $mYear.Index
            $usedYearAsDelimiter = $true
        }
    }
    
    if ($cutIndex -ge 0) {
        $show = $t.Substring(0, $cutIndex)
    }
    
    # Normalize delimiters (. _ - → space)
    $show = Normalize-Delimiters $show
    
    # Remove noise words
    $show = Remove-NoiseWords $show
    
    # Clean up extra spaces
    $show = $show -replace '\s+', ' '
    $show = $show.Trim()

    return @{ Matched=$true; Show=$show; Season=$season; Episode=$episode }
}

function ScoreAndClassifyArchive($fileInfo, $inSeasonFolder) {
    $fullPath = $fileInfo.FullName
    $baseName = $fileInfo.BaseName
    $p = $fullPath.ToLower()
    $sizeGB = [math]::Round($fileInfo.Length / 1GB, 3)

    # Path hints
    $pathMovieHint = ($p -match "\\movies\\") -or ($p -match "\\film\\") -or ($p -match "\\blu-?ray\\") -or ($p -match "\\dvds\\")
    $pathTvHint    = ($p -match "\\tv\\") -or ($p -match "\\tv shows\\") -or ($p -match "\\series\\") -or ($p -match "\\season")
    $pathAnimeHint = ($p -match "\\anime\\") -or ($fullPath -match '\[\w+-\w+\]') -or ($p -match "\\hentai\\")

    # Filename hints
    $isSeasonPattern = ($baseName -match '(?i)\bS\d{1,2}\b') -or ($baseName -match '(?i)\bSeason[\s\._-]*\d{1,2}\b') -or ($baseName -match '(?i)\bSeries[\s\._-]*\d{1,2}\b')
    $isEpisodePattern = ($baseName -match '(?i)\bS\d{1,2}E\d{1,2}\b') -or ($baseName -match '(?i)\b\d{1,2}x\d{1,2}\b')
    $hasCompleteKeyword = ($baseName -match '(?i)\bComplete\b') -or ($baseName -match '(?i)\bFull[\s\._-]*Season\b')
    $hasYear = ($baseName -match '(19|20)\d{2}')
    $hasQualityTag = ($baseName -match '(?i)BluRay|Remux|WEB-DL|HDTV|1080p|720p|2160p|4K')

    # Size-based heuristics for archives (rough estimates based on typical compression)
    # Single movie (1080p BluRay): 8-25 GB, 4K: 25-70+ GB
    # TV Season (10-24 episodes @ 720p-1080p): 15-80+ GB
    $looksMovieBySizeSmall  = ($sizeGB -ge 3 -and $sizeGB -le 15)    # Single compressed movie
    $looksMovieBySizeMedium = ($sizeGB -gt 15 -and $sizeGB -le 35)   # Higher quality movie
    $looksMovieBySizeLarge  = ($sizeGB -gt 35 -and $sizeGB -le 70)   # 4K movie or collection
    $looksSeasonBySize      = ($sizeGB -gt 8)                        # TV seasons typically 8GB+ for even short seasons
    $looksLargeSeasonBySize = ($sizeGB -gt 25)                       # Full seasons of 10+ episodes

    # Scores
    $scoreMovie = 0
    $scoreSeason = 0

    # Path scoring
    if ($pathMovieHint) { $scoreMovie += 40 }
    if ($pathTvHint)    { $scoreSeason += 40 }
    if ($pathAnimeHint) { $scoreSeason += 30 }
    if ($inSeasonFolder){ $scoreSeason += 35 }

    # Naming pattern scoring (strongest signals)
    if ($isSeasonPattern)    { $scoreSeason += 60 }
    if ($hasCompleteKeyword) { $scoreSeason += 30 }
    if ($isEpisodePattern)   { $scoreSeason += 20 }  # Single episode archive less common but boost season slightly
    
    # Size-based scoring with context
    if ($looksMovieBySizeSmall) {
        if ($isSeasonPattern) {
            $scoreSeason += 25  # Small archive with season keyword = short season
        } else {
            $scoreMovie += 30   # Small archive without season clues = likely single movie
        }
    }
    
    if ($looksMovieBySizeMedium) {
        if ($isSeasonPattern) {
            $scoreSeason += 35  # Medium archive with season pattern = likely season
        } else {
            $scoreMovie += 25   # Could be movie or short season, slightly favor movie
            $scoreSeason += 15
        }
    }
    
    if ($looksMovieBySizeLarge) {
        # Large archives need strong contextual signals
        if ($isSeasonPattern -or $hasCompleteKeyword) {
            $scoreSeason += 40  # Large + season markers = definitely a season
        } else {
            $scoreMovie += 20   # Large with no season clues = could be 4K movie or collection
            $scoreSeason += 20  # But also could be a season
        }
    }
    
    if ($looksLargeSeasonBySize) {
        $scoreSeason += 30  # Very large archives more likely to be full TV seasons
    }

    # Year + quality tags slightly favor movies but not strongly
    if ($hasYear -and $hasQualityTag -and -not $isSeasonPattern) { 
        $scoreMovie += 15 
    }

    # Decide category
    $cat = "Archive_Unknown"
    $confidence = 50

    if ($scoreMovie -gt $scoreSeason -and $scoreMovie -ge 40) {
        $cat = "Movie_Archive"
        $gap = $scoreMovie - $scoreSeason
        $confidence = [math]::Min(100, $scoreMovie + [math]::Ceiling($gap / 2))
    }
    elseif ($scoreSeason -gt $scoreMovie -and $scoreSeason -ge 40) {
        $cat = "TV_SeasonBundle"
        $gap = $scoreSeason - $scoreMovie
        $confidence = [math]::Min(100, $scoreSeason + [math]::Ceiling($gap / 2))
    }
    elseif ([math]::Abs($scoreMovie - $scoreSeason) -le 10 -and ($scoreMovie -ge 30 -or $scoreSeason -ge 30)) {
        $cat = "Archive_Ambiguous"
        $confidence = 50
    }

    # Extract show/season info if detected
    $showGuess = ""
    $seasonCode = ""
    $seasonInfo = SeasonInfoFromName $baseName
    if ($seasonInfo.Matched) {
        $showGuess = $seasonInfo.Show
        $seasonCode = $seasonInfo.Season
    }

    return @{ 
        Category=$cat
        Confidence=[int]$confidence
        ScoreMovie=$scoreMovie
        ScoreSeason=$scoreSeason
        ShowGuess=$showGuess
        SeasonGuess=$seasonCode
    }
}

function ScoreAndClassifyVideo($fileInfo, $durMin, $w, $h, $inSeasonFolder) {
    $fullPath = $fileInfo.FullName
    $baseName = $fileInfo.BaseName
    $p = $fullPath.ToLower()

    # Path hints
    $pathMovieHint = ($p -match "\\movies\\") -or ($p -match "\\film\\") -or ($p -match "\\blu-?ray\\") -or ($p -match "\\dvds\\")
    $pathTvHint    = ($p -match "\\tv\\") -or ($p -match "\\tv shows\\") -or ($p -match "\\series\\") -or ($p -match "\\season")
    $pathClipEntertainmentHint = ($p -match "\\clips\\") -or ($p -match "\\highlights\\") -or ($p -match "\\best[\s_\.-]*moments?\\") -or ($p -match "\\movie[\s_\.-]*gold\\") -or ($p -match "\\scenes\\") -or ($p -match "\\montage\\")
    $pathPersonalCaptureHint = ($p -match "\\obs\\") -or ($p -match "\\recordings\\") -or ($p -match "\\captures\\") -or ($p -match "\\gameplay\\") -or ($p -match "\\replays\\") -or ($p -match "\\raw[\s_\.-]*footage\\") -or ($p -match "\\shadowplay\\") -or ($p -match "\\stream")
    $pathAnimeHint = ($p -match "\\anime\\") -or ($fullPath -match '\[\w+-\w+\]') -or ($p -match "\\hentai\\")  # folder named anime, or [SubGroup] naming, or hentai folder

    # Filename hints
    $isEpisodePattern = ($baseName -match '(?i)\bS\d{1,2}E\d{1,2}\b') -or ($baseName -match '(?i)\b\d{1,2}x\d{1,2}\b') -or ($baseName -match '(?i)\bEp(?:isode)?[\s\._-]*\d{1,2}\b')
    # Entertainment clip keywords - movie/TV scenes, deleted scenes, etc.
    $hasClipKeyword = ($baseName -match '(?i)\bclip(?:s)?\b') -or ($baseName -match '(?i)\bhighlight(?:s)?\b') -or ($baseName -match '(?i)\bbest[\s_\.-]*moments?\b') -or ($baseName -match '(?i)\bmovie[\s_\.-]*gold\b') -or ($baseName -match '(?i)\bscene(?:s)?\b') -or ($baseName -match '(?i)\bmontage\b') -or ($baseName -match '(?i)\bcompilation\b') -or ($baseName -match '(?i)\bdeleted\b') -or ($baseName -match '(?i)\bextended\b') -or ($baseName -match '(?i)movieclips?')
    # Personal capture keywords - raw footage, stock, dev work, streams
    $hasPersonalCaptureKeyword = ($baseName -match '(?i)\bobs\b') -or ($baseName -match '(?i)\bcapture(?:s|d)?\b') -or ($baseName -match '(?i)\brecord(?:ing|ings)\b') -or ($baseName -match '(?i)[\s\._-]raw[\s\._-]?') -or ($baseName -match '(?i)^raw[\s\._-]') -or ($baseName -match '(?i)\bfootage\b') -or ($baseName -match '(?i)\bgameplay\b') -or ($baseName -match '(?i)\breplay\b') -or ($baseName -match '(?i)\bshadowplay\b') -or ($baseName -match '(?i)\bstock\b') -or ($baseName -match '(?i)\bstream(?:ing)?\b') -or ($baseName -match '(?i)\bdev[\s\._-]*diary\b') -or ($baseName -match '(?i)\bunfollow\b')
    $hasYear = ($baseName -match '(19|20)\d{2}')
    $hasQualityTag = ($baseName -match '(?i)BluRay|Remux|WEB-DL|HDTV')

    # Duration heuristics
    $looksMovieByDur = ($durMin -ge 70)
    $looksTvByDur    = ($durMin -ge 18 -and $durMin -le 70)
    $looksClipByDur  = ($durMin -gt 0 -and $durMin -lt 18)
    $looksClipishByDur = ($durMin -gt 0 -and $durMin -le 45)
    $looksShortFilmByDur = ($durMin -ge 30 -and $durMin -lt 70)  # short films: 30-70 min

    # Scores
    $scoreMovie = 0
    $scoreTv = 0
    $scoreClip = 0
    $scorePersonal = 0

    if ($pathMovieHint) { $scoreMovie += 35 }
    if ($pathTvHint)    { $scoreTv += 35 }
    if ($pathAnimeHint) { $scoreTv += 25 }  # anime folders lean toward TV but not as strongly as TV path
    if ($pathClipEntertainmentHint) { $scoreClip += 35 }
    if ($pathPersonalCaptureHint)   { $scorePersonal += 35 }
    if ($hasClipKeyword)            { $scoreClip += 40 }  # Strong signal for entertainment clips
    if ($hasPersonalCaptureKeyword) { $scorePersonal += 45 }  # Very strong signal for personal content

    if ($isEpisodePattern) { $scoreTv += 55 }
    if ($inSeasonFolder)   { $scoreTv += 35 }   # big boost if folder screams "season"

    if ($looksMovieByDur) { $scoreMovie += 35 }
    if ($looksTvByDur)    { $scoreTv += 25 }
    
    # Duration scoring with mutual exclusivity logic
    if ($looksClipByDur)  {
        # If it clearly has personal indicators, don't boost Clip
        if ($hasPersonalCaptureKeyword -or $pathPersonalCaptureHint) {
            $scorePersonal += 25
        }
        # If it clearly has entertainment clip indicators, don't boost Personal
        elseif ($hasClipKeyword -or $pathClipEntertainmentHint) {
            $scoreClip += 25
        }
        # Otherwise, could be either
        else {
            $scoreClip += 15
            $scorePersonal += 15
        }
    }
    
    if ($looksClipishByDur -and $hasClipKeyword) { $scoreClip += 15 }
    if ($looksClipishByDur -and ($pathPersonalCaptureHint -or $hasPersonalCaptureKeyword)) { $scorePersonal += 10 }
    if ($pathClipEntertainmentHint -and $hasYear -and -not $isEpisodePattern) { $scoreClip += 10 }

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
        [pscustomobject]@{ Cat="Clip"; Score=$scoreClip },
        [pscustomobject]@{ Cat="Personal"; Score=$scorePersonal }
    ) | Sort-Object Score -Descending

    $top = $scores[0]
    $second = $scores[1]
    $gap = $top.Score - $second.Score
    $confidence = [math]::Min(100, [math]::Max(0, ($top.Score + $gap)))

    $cat = $top.Cat
    if ($top.Score -lt 40 -or $gap -lt 12) { $cat = "Unknown" }

    return @{ Category=$cat; Confidence=[int]$confidence; ScoreMovie=$scoreMovie; ScoreTV=$scoreTv; ScoreClip=$scoreClip; ScorePersonal=$scorePersonal }
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
$movieArchiveCount = 0
$tvEpisodeCount = 0
$tvBundleCount = 0
$clipCount = 0
$personalCount = 0
$unknownCount = 0
$ambiguousCount = 0

# Helper to update progress
function Update-ScanProgress($currentName) {
    $pct = [int](($processed / $totalItems) * 100)
    $elapsed = (Get-Date) - $start
    $rate = if ($elapsed.TotalSeconds -gt 0) { $processed / $elapsed.TotalSeconds } else { 0 }
    $etaSec = if ($rate -gt 0) { [int](($totalItems - $processed) / $rate) } else { 0 }
    $eta = (New-TimeSpan -Seconds $etaSec)
    $statusLine = "Processed $processed/$totalItems | Movies:$movieCount M-Archives:$movieArchiveCount TVeps:$tvEpisodeCount TVbundles:$tvBundleCount Clips:$clipCount Personal:$personalCount Unknown:$unknownCount Ambig:$ambiguousCount | ffprobe fails:$ffprobeFailed | ETA: {0:hh\:mm\:ss}" -f $eta

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

    # Extract episode info for grouping
    $episodeInfo = EpisodeInfoFromName $fi.BaseName
    $showName = if ($episodeInfo.Matched) { $episodeInfo.Show } else { "" }
    $seasonNum = if ($episodeInfo.Matched) { $episodeInfo.Season } else { "" }
    $episodeNum = if ($episodeInfo.Matched) { $episodeInfo.Episode } else { "" }

    switch ($class.Category) {
        "Movie"      { $movieCount++ }
        "TV_Episode" { $tvEpisodeCount++ }
        "Clip"       { $clipCount++ }
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
        ScoreClip      = $class.ScoreClip
        ScorePersonal  = $class.ScorePersonal
        InSeasonFolder = $inSeasonFolder
        ShowName       = $showName
        SeasonNum      = $seasonNum
        EpisodeNum     = $episodeNum
        GroupID        = ""
        GroupType      = ""
        DuplicateOf    = ""
    }) | Out-Null

    Update-ScanProgress $fi.Name
}

# --- Archives (tar/zip/etc.) ---
foreach ($path in $archivePaths) {
    $processed++

    $fi = $null
    try { $fi = Get-Item -LiteralPath $path -ErrorAction Stop } catch { $fi = $null }
    if (-not $fi) { $unknownCount++; Update-ScanProgress (Split-Path $path -Leaf); continue }

    $dir = Split-Path $path -Parent
    $inSeasonFolder = $seasonFolderLookup.ContainsKey($dir)

    # Use the new classification function
    $class = ScoreAndClassifyArchive $fi $inSeasonFolder

    switch ($class.Category) {
        "Movie_Archive"      { $movieArchiveCount++ }
        "TV_SeasonBundle"    { $tvBundleCount++ }
        "Archive_Ambiguous"  { $ambiguousCount++ }
        default              { $unknownCount++ }
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
        AutoCategory   = $class.Category
        Confidence     = $class.Confidence
        ScoreMovie     = $class.ScoreMovie
        ScoreSeason    = $class.ScoreSeason
        ShowGuess      = $class.ShowGuess
        SeasonGuess    = $class.SeasonGuess
        InSeasonFolder = $inSeasonFolder
        ShowName       = $class.ShowGuess
        SeasonNum      = $class.SeasonGuess
        EpisodeNum     = ""
        GroupID        = ""
        GroupType      = ""
        DuplicateOf    = ""
    }) | Out-Null

    Update-ScanProgress $fi.Name
}

Write-Progress -Activity "Scanning $root media" -Completed

# ===== GROUPING PHASE =====
Write-Host ""
Write-Host "Analyzing groups and duplicates..." -ForegroundColor Cyan

$groupID = 1
$groupRows = New-Object System.Collections.Generic.List[Object]
$dupeRows = New-Object System.Collections.Generic.List[Object]
$virtualBundleCount = 0

# 1) Group loose video episodes into virtual season bundles
$videoFiles = $rows | Where-Object { $_.ItemType -eq "VideoFile" -and $_.ShowName -and $_.SeasonNum -and $_.EpisodeNum }
$grouped = $videoFiles | Group-Object { "$($_.ShowName)|$($_.SeasonNum)" }

foreach ($g in $grouped) {
    $episodes = @($g.Group)
    if ($episodes.Count -ge 3) {  # 3+ episodes = likely a season bundle
        $parts = $g.Name -split '\|'
        $showName = $parts[0]
        $seasonNum = $parts[1]
        
        $totalSizeGB = ($episodes | Measure-Object -Property SizeGB -Sum).Sum
        $totalDurMin = ($episodes | Measure-Object -Property DurationMin -Sum).Sum
        $episodeList = ($episodes | Sort-Object EpisodeNum | ForEach-Object { $_.EpisodeNum }) -join ", "
        
        # Assign group ID to all episodes in this virtual bundle
        $currentGroupID = "VB-$groupID"
        foreach ($ep in $episodes) {
            $ep.GroupID = $currentGroupID
            $ep.GroupType = "Virtual_SeasonBundle"
        }
        
        $groupRows.Add([pscustomobject]@{
            GroupID        = $currentGroupID
            GroupType      = "Virtual_SeasonBundle"
            ShowName       = $showName
            SeasonNum      = $seasonNum
            FileCount      = $episodes.Count
            TotalSizeGB    = [math]::Round($totalSizeGB, 2)
            TotalDurMin    = [math]::Round($totalDurMin, 2)
            Episodes       = $episodeList
            Representative = $episodes[0].FullPath
        }) | Out-Null
        
        $groupID++
        $virtualBundleCount++
    }
}

# 2) Detect duplicates: Archives that match extracted video groups
$archives = $rows | Where-Object { $_.ItemType -eq "Archive" -and $_.ShowName -and $_.SeasonNum }

foreach ($arc in $archives) {
    # Normalize show name for fuzzy matching (remove punctuation, extra spaces)
    $arcShowNorm = $arc.ShowName -replace '[^\w\s]', '' -replace '\s+', ' '
    $arcShowNorm = $arcShowNorm.Trim().ToLower()
    
    # Look for video episodes with matching show + season
    $matchingEpisodes = $videoFiles | Where-Object {
        $_.SeasonNum -eq $arc.SeasonNum -and
        (($_.ShowName -replace '[^\w\s]', '' -replace '\s+', ' ').Trim().ToLower()) -eq $arcShowNorm
    }
    
    if ($matchingEpisodes) {
        $epCount = @($matchingEpisodes).Count
        $epSizeGB = ($matchingEpisodes | Measure-Object -Property SizeGB -Sum).Sum
        $arcSizeGB = $arc.SizeGB
        
        # Consider it a duplicate if:
        # - Multiple episodes exist
        # - Archive size is within reasonable range of extracted episodes (50% to 200%)
        $sizeRatio = if ($epSizeGB -gt 0) { $arcSizeGB / $epSizeGB } else { 0 }
        
        if ($epCount -ge 3 -and $sizeRatio -ge 0.3 -and $sizeRatio -le 2.0) {
            $dupeGroupID = "DUPE-$groupID"
            
            # Mark archive as duplicate
            $arc.GroupID = $dupeGroupID
            $arc.GroupType = "Duplicate_Archive"
            $arc.DuplicateOf = "Extracted_In_Folder"
            
            # Mark episodes as having an archive duplicate
            foreach ($ep in $matchingEpisodes) {
                if (-not $ep.GroupType) { 
                    $ep.GroupType = "Has_Archive_Duplicate" 
                }
                $ep.DuplicateOf = $arc.FileName
            }
            
            $dupeRows.Add([pscustomobject]@{
                GroupID          = $dupeGroupID
                ArchiveFile      = $arc.FileName
                ArchiveSizeGB    = $arcSizeGB
                ExtractedCount   = $epCount
                ExtractedSizeGB  = [math]::Round($epSizeGB, 2)
                SizeRatio        = [math]::Round($sizeRatio, 2)
                ShowName         = $arc.ShowName
                SeasonNum        = $arc.SeasonNum
                ArchivePath      = $arc.FullPath
            }) | Out-Null
            
            $groupID++
        }
    }
}

Write-Host ("Virtual season bundles detected: {0}" -f $virtualBundleCount) -ForegroundColor DarkCyan
Write-Host ("Archive/Extracted duplicates found: {0}" -f $dupeRows.Count) -ForegroundColor DarkCyan

# Export all CSVs
$rows | Export-Csv $outItemsCsv -NoTypeInformation
$seasonFolderRows | Export-Csv $outSeasonsCsv -NoTypeInformation
if ($groupRows.Count -gt 0) {
    $groupRows | Export-Csv $outGroupsCsv -NoTypeInformation
}
if ($dupeRows.Count -gt 0) {
    $dupeRows | Export-Csv $outDupesCsv -NoTypeInformation
}

# Write error log to file
if ($errorLog.Count -gt 0) {
    $errorLog | Set-Content $ffprobeLog
}

$totalTime = (Get-Date) - $start
Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ("Wrote {0} rows -> {1}" -f $rows.Count, $outItemsCsv) -ForegroundColor Green
Write-Host ("Wrote {0} season folders -> {1}" -f $seasonFolderRows.Count, $outSeasonsCsv) -ForegroundColor Green
if ($groupRows.Count -gt 0) {
    Write-Host ("Wrote {0} virtual bundles -> {1}" -f $groupRows.Count, $outGroupsCsv) -ForegroundColor Green
}
if ($dupeRows.Count -gt 0) {
    Write-Host ("Wrote {0} duplicate groups -> {1}" -f $dupeRows.Count, $outDupesCsv) -ForegroundColor Green
}
Write-Host ("Totals: Movies={0} | MovieArchives={1} | TV_Episodes={2} | TV_Bundles={3} | Virtual_Bundles={4} | Clips={5} | Personal={6} | Ambiguous={7} | Unknown={8}" -f $movieCount,$movieArchiveCount,$tvEpisodeCount,$tvBundleCount,$virtualBundleCount,$clipCount,$personalCount,$ambiguousCount,$unknownCount)
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