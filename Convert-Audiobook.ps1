<#
.SYNOPSIS
    Merges multi-file MP3 audiobooks into single M4B files with chapters and cover art,
    showing live per-book progress in a GUI.

.DESCRIPTION
    Recursively scans -Root for MP3 files, groups them by their containing folder
    (one output book per folder). Books are converted in parallel (ffmpeg +
    AtomicParsley) on a background runspace while a WinForms window shows a live
    status grid (one row per book with its current step), an overall progress bar,
    and a combined log. Folders only show up here if source MP3s still exist,
    so any pre-existing .m4b in that folder is from a prior failed run and is
    always overwritten.

.PARAMETER Root
    Folder tree to scan for MP3 files (searched recursively).

.PARAMETER MaxParallel
    Number of books to convert concurrently. Defaults to the number of CPU cores.

.NOTES
    Requires ffmpeg and AtomicParsley on PATH. Requires PowerShell 7+ (ForEach-Object -Parallel).
#>
param(
    [string]$Root = "X:\",
    [int]$MaxParallel = [Environment]::ProcessorCount
)

# WinForms needs an STA thread; relaunch under -STA if we weren't started that way.
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $psExe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $psExe -ArgumentList @(
        '-NoProfile', '-STA', '-File', "`"$PSCommandPath`"",
        '-Root', "`"$Root`"", '-MaxParallel', $MaxParallel
    ) -Wait
    exit $LASTEXITCODE
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Write-Log($msg) {
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "$timestamp | $msg"
}

# Known install locations to fall back to if a tool isn't already on PATH.
$knownToolPaths = @{
    AtomicParsley = "C:\Tools\AtomicParsley"
}

foreach ($tool in @("ffmpeg", "AtomicParsley")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        $fallbackDir = $knownToolPaths[$tool]
        if ($fallbackDir -and (Test-Path (Join-Path $fallbackDir "$tool.exe"))) {
            Write-Log "'$tool' not on PATH; using $fallbackDir"
            $env:Path = "$fallbackDir;$env:Path"
        }
        else {
            Write-Log "ERROR: '$tool' was not found on PATH. Install it and try again."
            [System.Windows.Forms.MessageBox]::Show("'$tool' was not found on PATH. Install it and try again.", "Missing dependency", 'OK', 'Error') | Out-Null
            exit 1
        }
    }
}

Write-Log "==============================================="
Write-Log " MP3 -> M4B Conversion Pipeline (Windows)"
Write-Log " Root: $Root"
Write-Log "==============================================="

# Recursively find every MP3 (single pass, tolerant of long paths / access errors),
# then group by the folder that directly contains them so nested/multi-level
# author\book paths are all picked up.
$allMp3s = Get-ChildItem -Path $Root -Filter *.mp3 -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -notlike "*\#recycle*" }
$groups = @($allMp3s | Group-Object DirectoryName | Sort-Object Name)

if ($groups.Count -eq 0) {
    Write-Log "No folders containing MP3 files were found under $Root."
    [System.Windows.Forms.MessageBox]::Show("No folders containing MP3 files were found under $Root.", "Nothing to do", 'OK', 'Information') | Out-Null
    exit 0
}

Write-Log "Found $($groups.Count) book folder(s). Launching GUI..."

# ============================================================
# Thread-safe state shared between the worker runspace and the GUI
# ============================================================
$rows = [System.Collections.Concurrent.ConcurrentDictionary[string, psobject]]::new()
$logQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

foreach ($group in $groups) {
    $rows[$group.Name] = [PSCustomObject]@{
        Folder = $group.Name
        Status = "Queued"
        Detail = "$($group.Count) MP3 file(s)"
    }
}

# ============================================================
# Conversion pipeline - runs on a background runspace so the GUI stays responsive
# ============================================================
$conversionScript = {
    param($Groups, $MaxParallel, $Rows, $LogQueue)

    $Groups | ForEach-Object -ThrottleLimit $MaxParallel -Parallel {

        $rows = $using:Rows
        $logQueue = $using:LogQueue

        function Set-RowStatus($folderPath, $status, $detail) {
            $rows[$folderPath] = [PSCustomObject]@{ Folder = $folderPath; Status = $status; Detail = $detail }
        }

        function Add-LogLine($message, [switch]$IsError) {
            $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $line = "$timestamp | $message"
            $logQueue.Enqueue($line)
            if ($IsError) { Write-Host $line -ForegroundColor Red } else { Write-Host $line }
        }

        $group = $_
        $folderPath = $group.Name
        $mp3s = $group.Group | Sort-Object FullName
        if ($mp3s.Count -eq 0) { return }

        Add-LogLine "[$folderPath] Starting"

        # Note: folders only appear here if source MP3s still exist, which means
        # any .m4b already present is from a prior failed run - always overwrite it.
        $first = $mp3s[0]
        $title = [System.IO.Path]::GetFileNameWithoutExtension($first.Name)
        $output = Join-Path $folderPath "$title.m4b"
        $chapterFile = Join-Path $folderPath "chapters.txt"
        $coverFile = Join-Path $folderPath "cover.jpg"

        # Generate chapters file
        Set-RowStatus $folderPath "Running" "Generating chapters"
        Add-LogLine "[$folderPath] Generating chapters ($($mp3s.Count) tracks)"
        $chapterIndex = 1
        $chapterLines = @()
        foreach ($mp3 in $mp3s) {
            $chapterLines += "CHAPTER$chapterIndex=0"
            $chapterLines += "CHAPTER${chapterIndex}NAME=$([System.IO.Path]::GetFileNameWithoutExtension($mp3.Name))"
            $chapterIndex++
        }
        # utf8NoBOM (not ascii) so non-ASCII characters in track names survive intact
        $chapterLines | Out-File -Encoding utf8NoBOM $chapterFile

        # Extract cover art
        Set-RowStatus $folderPath "Running" "Extracting cover"
        Add-LogLine "[$folderPath] Extracting cover art"
        $coverOutput = & ffmpeg -i "$($first.FullName)" -an -vcodec copy "$coverFile" -y 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $coverFile)) {
            Add-LogLine "[$folderPath] WARNING: no cover art extracted, continuing without it`n$coverOutput" -IsError
            $coverFile = $null
        }

        # Merge MP3s -> M4B
        Set-RowStatus $folderPath "Running" "Merging MP3s"
        Add-LogLine "[$folderPath] Merging MP3 files"
        $concatList = Join-Path $folderPath "concat.txt"
        # ffmpeg's concat demuxer requires single quotes in paths to be escaped
        # utf8NoBOM (not ascii) so non-ASCII characters in file paths survive intact
        $mp3s | ForEach-Object { "file '$($_.FullName -replace "'", "'\''")'" } | Out-File -Encoding utf8NoBOM $concatList

        $mergeOutput = & ffmpeg -f concat -safe 0 -i "$concatList" -c:a aac -b:a 128k "$output" -y 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $output)) {
            Set-RowStatus $folderPath "Failed" "Merge failed, source MP3s kept"
            Add-LogLine "[$folderPath] ERROR: merge failed`n$mergeOutput" -IsError
            Remove-Item -Path $concatList -Force -ErrorAction SilentlyContinue
            return
        }

        # Add metadata + chapters + cover
        Set-RowStatus $folderPath "Running" "Embedding metadata"
        Add-LogLine "[$folderPath] Embedding metadata"
        $atomicArgs = @("$output", "--title", "$title", "--chapters", "$chapterFile", "--overWrite")
        if ($coverFile) { $atomicArgs += @("--artwork", "$coverFile") }
        $atomicOutput = & AtomicParsley @atomicArgs 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -and $atomicOutput -match "unrecognized option .?--chapters") {
            Add-LogLine "[$folderPath] WARNING: this AtomicParsley build does not support --chapters; retrying without it" -IsError
            $atomicArgs = @("$output", "--title", "$title", "--overWrite")
            if ($coverFile) { $atomicArgs += @("--artwork", "$coverFile") }
            $atomicOutput = & AtomicParsley @atomicArgs 2>&1 | Out-String
        }
        if ($LASTEXITCODE -ne 0) {
            Set-RowStatus $folderPath "Failed" "Metadata embedding failed, source MP3s kept"
            Add-LogLine "[$folderPath] ERROR: metadata embedding failed`n$atomicOutput" -IsError
            return
        }

        # Cleanup MP3 files
        Set-RowStatus $folderPath "Running" "Cleaning up"
        $mp3s | Remove-Item
        Remove-Item -Path $concatList -Force -ErrorAction SilentlyContinue

        Set-RowStatus $folderPath "Converted" "Done: $output"
        Add-LogLine "[$folderPath] Completed: $output"
    }
}

$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
$worker = [powershell]::Create()
$worker.Runspace = $runspace
[void]$worker.AddScript($conversionScript).AddArgument($groups).AddArgument($MaxParallel).AddArgument($rows).AddArgument($logQueue)
$asyncResult = $worker.BeginInvoke()

# ============================================================
# GUI
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "Audiobook Converter"
$form.Width = 1000
$form.Height = 700
$form.StartPosition = "CenterScreen"

$topPanel = New-Object System.Windows.Forms.TableLayoutPanel
$topPanel.Dock = "Top"
$topPanel.AutoSize = $true
$topPanel.ColumnCount = 1
$topPanel.RowCount = 2

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.Dock = "Fill"
$summaryLabel.AutoSize = $true
$summaryLabel.Padding = New-Object System.Windows.Forms.Padding(6)
$summaryLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$summaryLabel.Text = "Starting..."

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Dock = "Fill"
$progressBar.Height = 20
$progressBar.Minimum = 0
$progressBar.Maximum = $groups.Count

$topPanel.Controls.Add($summaryLabel, 0, 0)
$topPanel.Controls.Add($progressBar, 0, 1)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = "Fill"
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.SelectionMode = 'FullRowSelect'
[void]$grid.Columns.Add("Folder", "Folder")
[void]$grid.Columns.Add("Status", "Status")
[void]$grid.Columns.Add("Detail", "Detail")
$grid.Columns[0].FillWeight = 55
$grid.Columns[1].FillWeight = 15
$grid.Columns[2].FillWeight = 30

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = "Vertical"
$logBox.Dock = "Fill"
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)

$splitContainer = New-Object System.Windows.Forms.SplitContainer
$splitContainer.Dock = "Fill"
$splitContainer.Orientation = "Horizontal"
$splitContainer.Panel1.Controls.Add($grid)
$splitContainer.Panel2.Controls.Add($logBox)

$form.Controls.Add($splitContainer)
$form.Controls.Add($topPanel)
$form.Add_Shown({ $splitContainer.SplitterDistance = [int]($form.ClientSize.Height * 0.65) })

$script:jobFinalized = $false

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
    $line = $null
    while ($logQueue.TryDequeue([ref]$line)) {
        $logBox.AppendText("$line`r`n")
    }

    $grid.SuspendLayout()
    $grid.Rows.Clear()
    $sorted = $rows.Values | Sort-Object Folder
    foreach ($r in $sorted) {
        $rowIndex = $grid.Rows.Add($r.Folder, $r.Status, $r.Detail)
        $color = switch ($r.Status) {
            "Converted" { [System.Drawing.Color]::LightGreen }
            "Failed"    { [System.Drawing.Color]::LightSalmon }
            "Skipped"   { [System.Drawing.Color]::LightYellow }
            "Running"   { [System.Drawing.Color]::LightSkyBlue }
            default     { [System.Drawing.Color]::White }
        }
        $grid.Rows[$rowIndex].DefaultCellStyle.BackColor = $color
    }
    $grid.ResumeLayout()

    $converted = @($sorted | Where-Object { $_.Status -eq "Converted" }).Count
    $skipped = @($sorted | Where-Object { $_.Status -eq "Skipped" }).Count
    $failed = @($sorted | Where-Object { $_.Status -eq "Failed" }).Count
    $done = $converted + $skipped + $failed

    $progressBar.Value = [Math]::Min($done, $progressBar.Maximum)
    $summaryLabel.Text = "Converted: $converted   Skipped: $skipped   Failed: $failed   Remaining: $($groups.Count - $done) / $($groups.Count)"

    if ($asyncResult.IsCompleted -and -not $script:jobFinalized) {
        $script:jobFinalized = $true
        try {
            $worker.EndInvoke($asyncResult)
        }
        catch {
            Write-Host "Worker error: $($_.Exception.Message)" -ForegroundColor Red
            $logBox.AppendText("Worker error: $($_.Exception.Message)`r`n")
        }
        if ($worker.Streams.Error.Count -gt 0) {
            foreach ($e in $worker.Streams.Error) {
                Write-Host "Worker error: $e" -ForegroundColor Red
                $logBox.AppendText("Worker error: $e`r`n")
            }
        }
        $worker.Dispose()
        $runspace.Close()
        $form.Text = "Audiobook Converter - Done"
        $logBox.AppendText("===============================================`r`n")
        $logBox.AppendText("All done. Converted: $converted, Skipped: $skipped, Failed: $failed`r`n")
        Write-Log "All done. Converted: $converted, Skipped: $skipped, Failed: $failed"
    }
})
$timer.Start()

$form.Add_FormClosing({
    if (-not $asyncResult.IsCompleted) {
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Conversion is still running. Closing now will stop it and may leave partially-converted files. Close anyway?",
            "Conversion in progress", 'YesNo', 'Warning')
        if ($confirm -eq 'No') {
            $_.Cancel = $true
        }
    }
})

[void]$form.ShowDialog()
$timer.Stop()
