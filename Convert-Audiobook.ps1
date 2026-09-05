param(
    [string]$Root = "C:\Audiobooks"
)

function Write-Log($msg) {
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "$timestamp | $msg"
}

Write-Log "==============================================="
Write-Log " MP3 → M4B Conversion Pipeline (Windows)"
Write-Log " Root: $Root"
Write-Log "==============================================="

# Recursively find every MP3 (single pass, tolerant of long paths / access errors),
# then group by the folder that directly contains them so nested/multi-level
# author\book paths are all picked up.
$allMp3s = Get-ChildItem -Path $Root -Filter *.mp3 -Recurse -File -Force -ErrorAction SilentlyContinue
$groups = $allMp3s | Group-Object DirectoryName | Sort-Object Name

$total = $groups.Count
$index = 0

foreach ($group in $groups) {

    $folderPath = $group.Name
    $mp3s = $group.Group | Sort-Object FullName
    if ($mp3s.Count -eq 0) { continue }

    $index++
    Write-Log "--------------------------------------------------"
    Write-Log "[$index / $total] Processing: $folderPath"
    Write-Log "--------------------------------------------------"

    # Skip if M4B already exists
    if (Get-ChildItem -Path $folderPath -Filter *.m4b -Force -ErrorAction SilentlyContinue) {
        Write-Log "Skipping: M4B already exists"
        continue
    }

    $first = $mp3s[0]
    $title = [System.IO.Path]::GetFileNameWithoutExtension($first.Name)
    $output = Join-Path $folderPath "$title.m4b"
    $chapterFile = Join-Path $folderPath "chapters.txt"
    $coverFile = Join-Path $folderPath "cover.jpg"

    Write-Log "Book title: $title"
    Write-Log "Output file: $output"

    #
    # Generate chapters file
    #
    Write-Log "Generating chapters..."
    $chapterIndex = 1
    $chapterLines = @()

    foreach ($mp3 in $mp3s) {
        $chapterLines += "CHAPTER$chapterIndex=0"
        $chapterLines += "CHAPTER$chapterIndexNAME=$([System.IO.Path]::GetFileNameWithoutExtension($mp3.Name))"
        $chapterIndex++
    }

    $chapterLines | Out-File -Encoding ascii $chapterFile

    #
    # Extract cover art
    #
    Write-Log "Extracting cover..."
    & ffmpeg -i "$($first.FullName)" -an -vcodec copy "$coverFile" -y

    #
    # Merge MP3s → M4B
    #
    Write-Log "Merging MP3 files..."
    $concatList = Join-Path $folderPath "concat.txt"
    $mp3s | ForEach-Object { "file '$($_.FullName)'" } | Out-File -Encoding ascii $concatList

    & ffmpeg -f concat -safe 0 -i "$concatList" -c:a aac -b:a 128k "$output" -y

    #
    # Add metadata + chapters + cover
    #
    Write-Log "Embedding metadata..."
    & AtomicParsley "$output" --title "$title" --artwork "$coverFile" --chapters "$chapterFile" --overWrite

    #
    # Cleanup MP3 files
    #
    Write-Log "Cleaning up MP3 files..."
    $mp3s | Remove-Item

    Write-Log "✔ Completed: $output"
}

Write-Log "==============================================="
Write-Log " Done."
Write-Log "==============================================="
