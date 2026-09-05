<#
.SYNOPSIS
    Auto-organises audiobooks dropped into an Audiobookshelf drop folder.

.DESCRIPTION
    Triggers an Audiobookshelf (ABS) library scan of -DropRoot, reads back each
    discovered item's metadata (author, series, title), and moves its folder
    from the drop location into -LibraryRoot\Author\[Series\]Title. Runs a
    final ABS scan afterwards so the library reflects the new locations, and
    removes any now-empty folders left behind in the drop root.

.PARAMETER DropRoot
    Windows path to the drop folder (matches -ServerDropRoot on the ABS server).

.PARAMETER LibraryRoot
    Windows path where organised Author\Series\Title folders are created.

.PARAMETER ServerDropRoot
    Linux path ABS uses for the same drop folder (for path translation).

.PARAMETER ServerUrl
    Base URL of the Audiobookshelf server.

.PARAMETER ApiKey
    Audiobookshelf API key. Falls back to $env:ABS_API_KEY if not supplied.
    Never hard-code a real key here.

.PARAMETER DryRun
    Show what would happen (moves, deletes) without changing anything.
#>
param(
    [string]$DropRoot       = "X:\drop",
    [string]$LibraryRoot    = "X:\",
    [string]$ServerDropRoot = "/media/Audiobooks/drop",
    [string]$ServerUrl      = "http://:13378",
    [string]$ApiKey = "",
    [switch]$DryRun
)

# ============================================================
# Audiobookshelf Book Organiser
#
# Workflow:
#
#   X:\drop
#       |
#       v
#   ABS library scan
#       |
#       v
#   Find ABS library items under /media/Audiobooks/drop
#       |
#       v
#   Read ABS metadata
#       |
#       +-- Author
#       +-- Series
#       +-- Series sequence
#       +-- Title
#       |
#       v
#   Build Windows destination
#       |
#       v
#   Move entire audiobook folder
#       |
#       v
#   Final ABS scan
#
# No ASIN or ISBN is required.
# ============================================================


# ============================================================
# Configuration
# ============================================================

$LibraryId = ""

# Maximum time to wait for an ABS scan to complete
$ScanTimeoutSeconds = 120

# How often to check ABS while waiting for a scan
$ScanPollSeconds = 2


# ============================================================
# API KEY
# ============================================================

if (-not $ApiKey) {
    $ApiKey = $env:ABS_API_KEY
}

if (-not $ApiKey) {
    Write-Error @"
No Audiobookshelf API key supplied.

Either run:

    `$env:ABS_API_KEY = "YOUR_API_KEY"

or pass:

    -ApiKey "YOUR_API_KEY"

Do not hard-code your API key into this script.
"@
    exit 1
}


# ============================================================
# Normalise paths
# ============================================================

$DropRoot = [System.IO.Path]::GetFullPath($DropRoot)

if (-not (Test-Path -LiteralPath $DropRoot)) {
    Write-Error "Drop root does not exist: $DropRoot"
    exit 1
}

if (-not (Test-Path -LiteralPath $LibraryRoot)) {
    Write-Error "Library root does not exist: $LibraryRoot"
    exit 1
}

$ServerDropRoot = $ServerDropRoot.TrimEnd('/')


# ============================================================
# HTTP headers
# ============================================================

$Headers = @{
    Authorization = "Bearer $ApiKey"
}


# ============================================================
# Logging
# ============================================================

$log = [System.Collections.Generic.List[string]]::new()

function Write-Log {
    param(
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    Write-Host "[$timestamp] $Message" -ForegroundColor $Color

    $log.Add("[$timestamp] $Message")
}


# ============================================================
# Convert ABS server path to Windows path
# ============================================================

function Convert-FromServerPath {
    param(
        [Parameter(Mandatory)]
        [string]$ServerPath
    )

    $serverRoot = $ServerDropRoot.TrimEnd('/')

    # Normalise slashes
    $serverPathNormalised = $ServerPath.Replace('\', '/')

    # Case-insensitive check
    if (-not $serverPathNormalised.ToLower().StartsWith(
        ($serverRoot + "/").ToLower()
    )) {
        Write-Warning "ABS path is not inside ServerDropRoot:"
        Write-Warning "  ABS path : $ServerPath"
        Write-Warning "  Root     : $ServerDropRoot"

        return $null
    }

    # Get relative path
    $relative = $serverPathNormalised.Substring(
        ($serverRoot + "/").Length
    )

    # Convert to Windows path
    $relativeWindows = $relative -replace '/', '\'

    $windowsPath = Join-Path $DropRoot $relativeWindows

    return $windowsPath
}


# ============================================================
# Clean Windows filename/folder characters
# ============================================================

function Convert-ToSafeName {
    param(
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return "Unknown"
    }

    # Invalid Windows filename characters
    $safe = $Name -replace '[\\/:*?"<>|]', '_'

    # Remove control characters
    $safe = $safe -replace '[\x00-\x1F]', '_'

    # Windows doesn't like trailing periods/spaces
    $safe = $safe.TrimEnd('.', ' ')

    # Reserved Windows names
    if ($safe -match '^(CON|PRN|AUX|NUL|COM[0-9]+|LPT[0-9]+)$') {
        $safe = "_$safe"
    }

    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = "Unknown"
    }

    return $safe
}


# ============================================================
# Get ABS library information
# ============================================================

function Get-ABSLibrary {
    try {
        return Invoke-RestMethod `
            -Uri "$ServerUrl/api/libraries/$LibraryId" `
            -Method GET `
            -Headers $Headers `
            -ErrorAction Stop
    }
    catch {
        Write-Error "Unable to retrieve Audiobookshelf library."
        Write-Error $_.Exception.Message
        return $null
    }
}


# ============================================================
# Start ABS scan
# ============================================================

function Start-ABSScan {
    param(
        [string]$Reason = "library scan"
    )

    Write-Log "Starting ABS $Reason..." Cyan

    try {
        $result = Invoke-RestMethod `
            -Uri "$ServerUrl/api/libraries/$LibraryId/scan" `
            -Method POST `
            -Headers $Headers `
            -ErrorAction Stop

        Write-Log "ABS scan started successfully." Green

        return $true
    }
    catch {
        Write-Log "ABS scan failed: $($_.Exception.Message)" Red
        return $false
    }
}


function Wait-ForABSDiscovery {
    param(
        [int]$TimeoutSeconds = 120,
        [int]$PollSeconds = 3
    )

    Write-Log "Waiting for ABS to discover books in drop folder..."

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        try {
            $items = Get-ABSItems

            $dropItems = @(
                $items | Where-Object {
                    $_.path -like "$ServerDropRoot/*" -and
                    $_.isMissing -ne $true -and
                    $_.isInvalid -ne $true
                }
            )

            if ($dropItems.Count -gt 0) {
                Write-Log "ABS has discovered $($dropItems.Count) audiobook(s) in the drop folder."
                return $true
            }

            Write-Log "No drop-folder books discovered yet. Checking again..."
        }
        catch {
            Write-Log "Error checking ABS library: $($_.Exception.Message)" "WARN"
        }

        Start-Sleep -Seconds $PollSeconds

    } while ((Get-Date) -lt $deadline)

    Write-Log "Timed out waiting for ABS to discover books." "WARN"

    return $false
}


# ============================================================
# Get all ABS items
# ============================================================

function Get-ABSItems {
    $allItems = @()
    $page = 0
    $limit = 100

    do {
        $url = "$ServerUrl/api/libraries/$LibraryId/items?limit=$limit&page=$page"

        Write-Log "Reading ABS library page $page..."

        $response = Invoke-RestMethod `
            -Uri $url `
            -Method Get `
            -Headers $Headers `
            -ErrorAction Stop

        if ($response.results) {
            $allItems += @($response.results)
        }

        $total = [int]$response.total

        Write-Log "ABS returned $($response.results.Count) items. Total library items: $total"

        $page++

    } while ($allItems.Count -lt $total -and $response.results.Count -gt 0)

    return $allItems
}

# ============================================================
# Get full ABS item
# ============================================================

function Get-ABSItem {
    param(
        [Parameter(Mandatory)]
        [string]$ItemId
    )

    try {

        return Invoke-RestMethod `
            -Uri "$ServerUrl/api/items/$ItemId" `
            -Method GET `
            -Headers $Headers `
            -ErrorAction Stop

    }
    catch {

        Write-Log "Unable to retrieve ABS item $ItemId : $($_.Exception.Message)" Red

        return $null
    }
}


# ============================================================
# Extract author name
# ============================================================

function Get-ABSAuthor {
    param(
        $Metadata
    )

    if (
        $Metadata.authors -and
        $Metadata.authors.Count -gt 0
    ) {
        $names = @(
            $Metadata.authors |
            Where-Object { $_.name } |
            ForEach-Object { $_.name.Trim() } |
            Where-Object { $_ }
        )

        if ($names.Count -gt 0) {
            return ($names -join ", ")
        }
    }

    return "Unknown Author"
}


# ============================================================
# Extract series information
# ============================================================

function Get-ABSPrimarySeries {
    param(
        $Metadata
    )

    if (
        $Metadata.series -and
        $Metadata.series.Count -gt 0
    ) {
        return $Metadata.series[0]
    }

    return $null
}


# ============================================================
# Build series folder name
# ============================================================

function Build-SeriesFolderName {
    param(
        $Series
    )

    if (-not $Series) {
        return $null
    }

    $seriesName = Convert-ToSafeName $Series.name

    $sequence = $Series.sequence

    if (
        $null -eq $sequence -or
        [string]::IsNullOrWhiteSpace("$sequence")
    ) {
        return $seriesName
    }

    $sequenceString = "$sequence".Trim()

    # If it's a simple integer, zero-pad to two digits.
    #
    # 1  -> 01
    # 2  -> 02
    # 17 -> 17
    # 100 -> 100
    #
    # This also preserves things such as:
    # 1.5
    # 0.5
    # 1A
    #
    if ($sequenceString -match '^\d+$') {

        try {
            $number = [int]$sequenceString

            return "{0:D2} - {1}" -f $number, $seriesName
        }
        catch {
            return "$sequenceString - $seriesName"
        }
    }

    return "$sequenceString - $seriesName"
}


# ============================================================
# Build target folder
# ============================================================

function Build-TargetFolder {
    param(
        [Parameter(Mandatory)]
        $Metadata
    )

    $author = Get-ABSAuthor -Metadata $Metadata

    $title = $Metadata.title

    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = "Unknown Title"
    }

    $author = Convert-ToSafeName $author
    $title  = Convert-ToSafeName $title

    $series = Get-ABSPrimarySeries -Metadata $Metadata

    $authorFolder = Join-Path $LibraryRoot $author

    if ($series) {

        $seriesFolderName = Build-SeriesFolderName -Series $series

        $seriesFolder = Join-Path `
            $authorFolder `
            (Convert-ToSafeName $seriesFolderName)

        $targetFolder = Join-Path `
            $seriesFolder `
            $title
    }
    else {

        $targetFolder = Join-Path `
            $authorFolder `
            $title
    }

    return $targetFolder
}


# ============================================================
# Move audiobook folder
# ============================================================

function Test-AudiobookFoldersMatch {
    param(
        [Parameter(Mandatory)]
        [string]$SourceFolder,

        [Parameter(Mandatory)]
        [string]$TargetFolder
    )

    try {
        $sourceFiles = @(Get-ChildItem -LiteralPath $SourceFolder -File -Recurse -Force -ErrorAction Stop)
        $targetFiles = @(Get-ChildItem -LiteralPath $TargetFolder -File -Recurse -Force -ErrorAction Stop)

        if ($sourceFiles.Count -ne $targetFiles.Count) {
            return $false
        }

        $targetByRelativePath = @{}

        foreach ($targetFile in $targetFiles) {
            $relativePath = $targetFile.FullName.Substring($TargetFolder.Length).TrimStart('\', '/')
            $targetByRelativePath[$relativePath] = $targetFile
        }

        foreach ($sourceFile in $sourceFiles) {
            $relativePath = $sourceFile.FullName.Substring($SourceFolder.Length).TrimStart('\', '/')

            if (-not $targetByRelativePath.ContainsKey($relativePath)) {
                return $false
            }

            $targetFile = $targetByRelativePath[$relativePath]

            if ($sourceFile.Length -ne $targetFile.Length) {
                return $false
            }

            $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            $targetHash = (Get-FileHash -LiteralPath $targetFile.FullName -Algorithm SHA256 -ErrorAction Stop).Hash

            if ($sourceHash -ne $targetHash) {
                return $false
            }
        }

        return $true
    }
    catch {
        Write-Log "Could not compare audiobook folders: $($_.Exception.Message)" Yellow
        return $false
    }
}


function Move-AudiobookFolder {
    param(
        [Parameter(Mandatory)]
        [string]$SourceFolder,

        [Parameter(Mandatory)]
        [string]$TargetFolder
    )

    if (-not (Test-Path -LiteralPath $SourceFolder)) {

        Write-Log "SOURCE DOES NOT EXIST: $SourceFolder" Red

        return $false
    }

    if ($DryRun) {

        if (Test-Path -LiteralPath $TargetFolder) {
            if (Test-AudiobookFoldersMatch -SourceFolder $SourceFolder -TargetFolder $TargetFolder) {
                Write-Log "[DRY-RUN] Source matches existing destination; would remove source: $SourceFolder" Cyan
            }
            else {
                Write-Log "[DRY-RUN] Source differs; would replace destination: $TargetFolder" Cyan
                Write-Log "[DRY-RUN] Would move: $SourceFolder -> $TargetFolder" Cyan
            }
        }
        else {
            Write-Log "[DRY-RUN] Would create: $TargetFolder" Cyan
            Write-Log "[DRY-RUN] Would move: $SourceFolder -> $TargetFolder" Cyan
        }

        return $true
    }

    try {

        if (Test-Path -LiteralPath $TargetFolder) {

            if (Test-AudiobookFoldersMatch -SourceFolder $SourceFolder -TargetFolder $TargetFolder) {

                Write-Log "Source matches existing destination. Removing source: $SourceFolder" Yellow

                Remove-Item `
                    -LiteralPath $SourceFolder `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop

                Write-Log "Source removed; destination already contains the same files." Green

                return $true
            }

            Write-Log "Source differs from existing destination. Replacing: $TargetFolder" Yellow

            Remove-Item `
                -LiteralPath $TargetFolder `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }

        $parentFolder = Split-Path `
            -Path $TargetFolder `
            -Parent

        if (-not (Test-Path -LiteralPath $parentFolder)) {

            Write-Log "Creating: $parentFolder" DarkCyan

            New-Item `
                -ItemType Directory `
                -Path $parentFolder `
                -Force `
                -ErrorAction Stop |
                Out-Null
        }

        Write-Log "Moving folder:" White
        Write-Log "  FROM: $SourceFolder" White
        Write-Log "  TO  : $TargetFolder" White

        Move-Item `
            -LiteralPath $SourceFolder `
            -Destination $TargetFolder `
            -ErrorAction Stop

        Write-Log "Move successful." Green

        return $true
    }
    catch {

        Write-Log "MOVE FAILED: $($_.Exception.Message)" Red

        return $false
    }
}


# ============================================================
# Remove empty directories
# ============================================================

function Remove-EmptyDropDirectories {

    Write-Log "Checking for empty directories in drop..." Cyan

    $removed = 0

    try {

        $directories = Get-ChildItem `
            -LiteralPath $DropRoot `
            -Directory `
            -Recurse `
            -Force |
            Sort-Object FullName -Descending

        foreach ($directory in $directories) {

            $children = Get-ChildItem `
                -LiteralPath $directory.FullName `
                -Force `
                -ErrorAction SilentlyContinue

            if ($children.Count -eq 0) {

                if ($DryRun) {

                    Write-Log "[DRY-RUN] Would remove empty folder: $($directory.FullName)" Cyan

                }
                else {

                    try {

                        Remove-Item `
                            -LiteralPath $directory.FullName `
                            -Force `
                            -ErrorAction Stop

                        Write-Log "Removed empty folder: $($directory.FullName)" DarkGray
                    }
                    catch {

                        Write-Log "Could not remove: $($directory.FullName)" Yellow
                        continue
                    }
                }

                $removed++
            }
        }
    }
    catch {

        Write-Log "Error while cleaning empty folders: $($_.Exception.Message)" Yellow
    }

    return $removed
}


# ============================================================
# Remove metadata and archive helper files before scanning
# ============================================================

function Remove-DropJunkFiles {

    Write-Log "Checking drop folder for .nfo, .jpg, and .sfv files..." Cyan

    $removed = 0

    try {

        $files = Get-ChildItem `
            -LiteralPath $DropRoot `
            -File `
            -Recurse `
            -Force `
            -ErrorAction Stop |
            Where-Object { $_.Extension -in @('.nfo', '.jpg', '.sfv', '.txt') }

        foreach ($file in $files) {

            if ($DryRun) {

                Write-Log "[DRY-RUN] Would remove: $($file.FullName)" Cyan
            }
            else {

                try {

                    Remove-Item `
                        -LiteralPath $file.FullName `
                        -Force `
                        -ErrorAction Stop

                    Write-Log "Removed: $($file.FullName)" DarkGray
                }
                catch {

                    Write-Log "Could not remove $($file.FullName): $($_.Exception.Message)" Yellow
                    continue
                }
            }

            $removed++
        }
    }
    catch {

        Write-Log "Error while removing drop helper files: $($_.Exception.Message)" Yellow
    }

    Write-Log "Drop helper files removed: $removed" Green

    return $removed
}


# ============================================================
# MAIN
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Audiobookshelf Automatic Book Organiser" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Server       : $ServerUrl"
Write-Host "Library ID   : $LibraryId"
Write-Host "Drop root    : $DropRoot"
Write-Host "Library root : $LibraryRoot"
Write-Host "ABS drop     : $ServerDropRoot"

if ($DryRun) {
    Write-Host ""
    Write-Host "***** DRY RUN *****" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host ""


# ============================================================
# Pre-scan cleanup
# ============================================================

$removedJunkFiles = Remove-DropJunkFiles


# ============================================================
# Verify ABS
# ============================================================

Write-Log "Testing Audiobookshelf API..." Cyan

$library = Get-ABSLibrary

if (-not $library) {
    Write-Error "Audiobookshelf API test failed."
    exit 1
}

Write-Log "Connected to Audiobookshelf." Green

Write-Log "ABS library: $($library.name)" Green
Write-Log "ABS path   : $($library.folders[0].fullPath)" Green
Write-Log "ABS version: $($library.lastScanVersion)" Green


# ============================================================
# Initial ABS scan
# ============================================================

$previousScan = [long]$library.lastScan

if (-not (Start-ABSScan -Reason "initial library scan")) {
    Write-Error "Could not start ABS scan."
    exit 1
}

if (-not (Wait-ForABSDiscovery)) {
    Write-Error "ABS did not discover any books in the drop folder."
    exit 1
}


# ============================================================
# Get ABS items
# ============================================================

Write-Log "Retrieving Audiobookshelf library items..." Cyan

$items = @(Get-ABSItems)

Write-Log "ABS returned $($items.Count) library items." Green


# ============================================================
# Select items inside drop folder
# ============================================================

$serverDropPrefix = $ServerDropRoot.TrimEnd('/') + '/'

$dropItems = @(
    $items |
    Where-Object {
        $_.path -and
        $_.path.Replace('\','/').ToLower().StartsWith(
            $serverDropPrefix.ToLower()
        ) -and
        -not $_.isMissing -and
        -not $_.isInvalid
    }
)

Write-Log "Found $($dropItems.Count) audiobook items in the ABS drop folder." Green


if ($dropItems.Count -eq 0) {

    Write-Log "Nothing to process." Yellow

    $removed = Remove-EmptyDropDirectories

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " Summary"
    Write-Host "============================================================"
    Write-Host "Books found      : 0"
    Write-Host "Books moved      : 0"
    Write-Host "Books skipped    : 0"
    Write-Host "Folders removed  : $removed"
    Write-Host "============================================================"
    Write-Host ""

    exit 0
}


# ============================================================
# Counters
# ============================================================

$totalItems     = $dropItems.Count
$movedCount     = 0
$skippedCount   = 0
$failedCount    = 0
$metadataErrors = 0


# ============================================================
# Process each ABS item
# ============================================================

$current = 0

foreach ($listItem in $dropItems) {

    $current++

    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "[$current/$totalItems] Processing ABS item" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray

    Write-Log "ABS Item ID: $($listItem.id)"
    Write-Log "ABS Path   : $($listItem.path)"


    # --------------------------------------------------------
    # Convert ABS path to Windows path
    # --------------------------------------------------------

    $sourceFolder = Convert-FromServerPath `
        -ServerPath $listItem.path

    if (-not $sourceFolder) {

        Write-Log "Could not convert ABS path to Windows path." Red

        $failedCount++

        continue
    }

    Write-Log "Windows source: $sourceFolder"


    # --------------------------------------------------------
    # ABS may return a single audiobook file (for example, an .m4b)
    # instead of its containing folder. Move the folder consistently.
    # --------------------------------------------------------

    if (Test-Path -LiteralPath $sourceFolder -PathType Leaf) {

        $sourceFolder = Split-Path -Path $sourceFolder -Parent

        Write-Log "Audiobook file detected; using containing folder: $sourceFolder"
    }


    # --------------------------------------------------------
    # Verify source folder
    # --------------------------------------------------------

    if (-not (Test-Path -LiteralPath $sourceFolder)) {

        Write-Log "Source folder does not exist: $sourceFolder" Red

        $failedCount++

        continue
    }


    # --------------------------------------------------------
    # Get complete ABS metadata
    # --------------------------------------------------------

    Write-Log "Retrieving full ABS metadata..." Cyan

    $absItem = Get-ABSItem -ItemId $listItem.id

    if (-not $absItem) {

        Write-Log "Could not retrieve ABS metadata." Red

        $metadataErrors++

        continue
    }


    # --------------------------------------------------------
    # Metadata
    # --------------------------------------------------------

    $metadata = $absItem.media.metadata

    if (-not $metadata) {

        Write-Log "ABS item contains no metadata." Red

        $metadataErrors++

        continue
    }


    # --------------------------------------------------------
    # Extract metadata
    # --------------------------------------------------------

    $author = Get-ABSAuthor -Metadata $metadata

    $title = $metadata.title

    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = "Unknown Title"
    }

    $series = Get-ABSPrimarySeries -Metadata $metadata

    $seriesName = ""
    $seriesSequence = ""

    if ($series) {

        $seriesName = $series.name

        if ($null -ne $series.sequence) {
            $seriesSequence = "$($series.sequence)"
        }
    }


    # --------------------------------------------------------
    # Display metadata
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "ABS Metadata" -ForegroundColor Magenta
    Write-Host "  Title    : $title"
    Write-Host "  Author   : $author"

    if ($series) {
        Write-Host "  Series   : $seriesName"
        Write-Host "  Sequence : $seriesSequence"
    }
    else {
        Write-Host "  Series   : <none>"
    }

    if ($metadata.asin) {
        Write-Host "  ASIN     : $($metadata.asin)"
    }

    if ($metadata.isbn) {
        Write-Host "  ISBN     : $($metadata.isbn)"
    }


    # --------------------------------------------------------
    # Build target folder
    # --------------------------------------------------------

    $targetFolder = Build-TargetFolder `
        -Metadata $metadata

    Write-Host ""
    Write-Host "Destination" -ForegroundColor Magenta
    Write-Host "  $targetFolder"


    # --------------------------------------------------------
    # Prevent moving a folder onto itself
    # --------------------------------------------------------

    try {

        $sourceFull = [System.IO.Path]::GetFullPath($sourceFolder).TrimEnd('\')
        $targetFull = [System.IO.Path]::GetFullPath($targetFolder).TrimEnd('\')

        if (
            $sourceFull.Equals(
                $targetFull,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {

            Write-Log "Source and destination are identical. Skipping." Yellow

            $skippedCount++

            continue
        }
    }
    catch {
        # Continue if path comparison fails
    }


    # --------------------------------------------------------
    # Move folder
    # --------------------------------------------------------

    $moved = Move-AudiobookFolder `
        -SourceFolder $sourceFolder `
        -TargetFolder $targetFolder

    if ($moved) {

        $movedCount++

    }
    else {

        $failedCount++
    }
}


# ============================================================
# Clean empty directories
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Cleaning drop folder" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$removedFolders = Remove-EmptyDropDirectories


# ============================================================
# Final ABS scan
# ============================================================

if (-not $DryRun) {

    Write-Host ""
    Write-Log "Starting final ABS scan..." Cyan

    $libraryAfterMoves = Get-ABSLibrary

    if ($libraryAfterMoves) {

        $previousScan = [long]$libraryAfterMoves.lastScan

        if (Start-ABSScan -Reason "final post-move scan") {

            Wait-ForABSScan -PreviousScan $previousScan | Out-Null
        }
    }
}
else {

    Write-Log "[DRY-RUN] Final ABS scan not performed." Yellow
}


# ============================================================
# Summary
# ============================================================

Write-Host ""
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Write-Host ("ABS items found       : {0}" -f $totalItems)
Write-Host ("Moved                 : {0}" -f $movedCount)
Write-Host ("Skipped (exists)      : {0}" -f $skippedCount)
Write-Host ("Failed                : {0}" -f $failedCount)
Write-Host ("Metadata errors       : {0}" -f $metadataErrors)
Write-Host ("Empty folders removed : {0}" -f $removedFolders)

if ($DryRun) {
    Write-Host ""
    Write-Host "***** DRY RUN - NO FILES WERE MOVED *****" -ForegroundColor Yellow
}

Write-Host "============================================================"
Write-Host ""


# ============================================================
# Detailed log
# ============================================================

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " DETAILED LOG" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

foreach ($entry in $log) {
    Write-Host $entry
}

Write-Host "============================================================"
Write-Host ""
Write-Host "Done." -ForegroundColor Green
