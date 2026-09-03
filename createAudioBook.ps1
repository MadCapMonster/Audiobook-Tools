
<#
.SYNOPSIS
    Converts a text file or web page into an M4B audiobook using audiblez and FFmpeg.

.DESCRIPTION
    Sets up a Python virtual environment with audiblez (installing Python 3.11 and
    FFmpeg via winget if needed), optionally downloads and cleans up a web page using
    a per-website parser, converts the text to an EPUB, generates narrated audio with
    audiblez (using CUDA if available), and re-encodes the result to a player-compatible M4B.

.PARAMETER Url
    Optional web page to download and use instead of an existing local text file.
    The downloaded content is cleaned up with a per-website parser (see handlers\ folder)
    and written to -textFile.

.PARAMETER VenvPath
    Path to the Python virtual environment. Reused if it already exists.

.PARAMETER textFile
    The source text file to convert. If -Url is given, this is where the
    downloaded/cleaned text is saved.

.PARAMETER outputBaseFolder
    Root folder for generated output. Each book gets its own subfolder.

.PARAMETER voice
    The audiblez narration voice to use.

.EXAMPLE
    .\CreateAudioBook.ps1 -textFile "Beginnings.txt"

.EXAMPLE
    .\CreateAudioBook.ps1 -Url "https://parahumans.wordpress.com/2011/06/11/1-1/" -textFile "Worm-1.1.txt"

.NOTES
    See README.md for details on the website parser (handlers\) system.
#>
[CmdletBinding()]
param(
    [string]$Url = "",
    [string]$VenvPath = ".\audiblez-env",
    [string]$textFile = "Beginnings.txt",
    [string]$outputBaseFolder = "C:\audiblez\output-audio",
    [string]$voice = "af_bella"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $outputBaseFolder)) {
    New-Item -ItemType Directory -Path $outputBaseFolder -Force | Out-Null
}

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Ensure-Python311 {
    $installed = & py -3.11 -c "print('ok')" 2>$null
    if ($LASTEXITCODE -eq 0 -and $installed -eq "ok") {
        Write-Step "Python 3.11 already installed"
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "Python 3.11 not found and winget is unavailable to install it. Install Python 3.11 manually."
    }

    Write-Step "Python 3.11 not found, installing via winget..."
    winget install --id Python.Python.3.11 --source winget --accept-package-agreements --accept-source-agreements

    & py -3.11 -c "print('ok')" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Python 3.11 installation failed or is not on PATH yet. Restart the shell and try again."
    }
}

function Ensure-FFmpeg {
    if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
        Write-Step "FFmpeg already installed"
        return
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "FFmpeg not found and winget is unavailable to install it. Install FFmpeg manually."
    }

    Write-Step "FFmpeg not found, installing via winget..."
    winget install --id Gyan.FFmpeg --source winget --accept-package-agreements --accept-source-agreements

    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        throw "FFmpeg installation failed or is not on PATH yet. Restart the shell and try again."
    }
}

function ConvertHtmlToText {
    param([string]$Html)

    $text = $Html -replace '(?is)<(script|style).*?>.*?</\1>', ''
    $text = $text -replace '(?is)<(p|div|br|/p|/div|h[1-6])\s*/?>', "`n"
    $text = $text -replace '(?is)<.*?>', ''
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = $text -replace '[ \t]+', ' '
    $text = $text -replace '(\r?\n\s*){3,}', "`n`n"
    return $text.Trim()
}

function Get-HandlerScriptPath {
    param([string]$HostName)

    $handlersFolder = Join-Path $PSScriptRoot "handlers"
    $handlerPath = Join-Path $handlersFolder "$HostName.ps1"
    if (Test-Path $handlerPath) {
        return $handlerPath
    }

    # No parser exists yet for this website - create one from the default
    # template so it can be found (and customized) next time.
    $defaultHandlerPath = Join-Path $handlersFolder "default.ps1"
    Write-Step "No parser found for '$HostName', creating one from the default template"
    Copy-Item -Path $defaultHandlerPath -Destination $handlerPath
    return $handlerPath
}

function Get-TextFromUrl {
    param([string]$Url, [string]$OutputTextFile)

    Write-Step "Downloading $Url"
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing
    $plainText = ConvertHtmlToText -Html $response.Content

    $uri = [System.Uri]$Url
    $handlerPath = Get-HandlerScriptPath -HostName $uri.Host
    Write-Step "Using cleanup handler: $handlerPath"
    . $handlerPath

    $bookName = [System.IO.Path]::GetFileNameWithoutExtension($OutputTextFile)
    $cleaned = Invoke-ContentCleanup -Content $plainText -BaseName $bookName

    Set-Content -Path $OutputTextFile -Value $cleaned
}

function ConvertTxt2Epub {
    param(
        [string]$TextFile,
        [string]$OutputFile
    )

    if (-not (Test-Path $TextFile)) {
        throw "Text file not found: $TextFile"
    }

    $outputFolder = Split-Path -Parent $OutputFile
    if (-not (Test-Path $outputFolder)) {
        New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
    }

    if (Test-Path $OutputFile) {
        Write-Step "Removing existing EPUB: $OutputFile"
        Remove-Item -Path $OutputFile -Force
    }

    Write-Step "Converting $TextFile to $OutputFile"
    $converterScript = Join-Path $PSScriptRoot "convert_txt_to_epub.py"
    python $converterScript $TextFile $OutputFile
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to convert $TextFile to EPUB"
    }
}

Ensure-FFmpeg

if (Test-Path (Join-Path $VenvPath "Scripts\python.exe")) {
    Write-Step "Virtual environment already exists at $VenvPath, skipping creation"
} else {
    Ensure-Python311
    Write-Step "Creating virtual environment with Python 3.11 at $VenvPath"
    py -3.11 -m venv $VenvPath
}

$activateScript = Join-Path $VenvPath "Scripts\Activate.ps1"
if (-not (Test-Path $activateScript)) {
    throw "Activation script not found at $activateScript"
}

Write-Step "Activating virtual environment"
. $activateScript

Write-Step "Upgrading pip"
python -m pip install --upgrade pip

Write-Step "Installing audiblez, pillow, wxpython"
pip install audiblez pillow wxpython pypub3

Write-Step "Checking PyTorch CUDA support"
$torchCudaOk = (python -c "import torch; print(torch.cuda.is_available())" 2>$null).Trim()
if ($torchCudaOk -eq "True") {
    Write-Step "CUDA-enabled PyTorch already installed, skipping reinstall"
} else {
    Write-Step "Installing CUDA-enabled PyTorch build"
    pip install torch --index-url https://download.pytorch.org/whl/cu121
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install CUDA-enabled torch build"
    }
}

if ($Url) {
    Get-TextFromUrl -Url $Url -OutputTextFile $textFile
}

Write-Step "Done. Virtual environment ready at $VenvPath"

$outputPath = Join-Path $outputBaseFolder ([System.IO.Path]::GetFileNameWithoutExtension($textFile))

$outputEpubFile = Join-Path $outputPath ([System.IO.Path]::GetFileNameWithoutExtension($textFile) + ".epub")
if (-not (Test-Path $outputPath)) {
    New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
}

Write-Step "Converting $textFile to EPUB"

ConvertTxt2Epub -TextFile $textFile -OutputFile $outputEpubFile
Write-Step "EPUB file created at $outputEpubFile"

# create the audio book from the EPUB file using audiblez
Write-Step "Creating audio book from $outputEpubFile"
$outputAudioFile = Join-Path $outputPath ([System.IO.Path]::GetFileNameWithoutExtension($textFile) + ".m4b")

$cudaAvailable = (python -c "import torch; print(torch.cuda.is_available())" 2>$null).Trim()
$audiblezArgs = @("$outputEpubFile", "-v", "$voice", "-o", "$outputPath")
if ($cudaAvailable -eq "True") {
    Write-Step "CUDA GPU detected, enabling GPU acceleration"
    $audiblezArgs += "-c"
} else {
    Write-Step "CUDA GPU not available, using CPU"
}

audiblez @audiblezArgs
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create audio book from $outputEpubFile"
}
Write-Step "Audio book created at $outputAudioFile"

# need the to be compatible with standard players, re-encode the audio
ffmpeg -y -i "$outputAudioFile" -map 0:a -map 0:v? -c:v copy -c:a aac -b:a 128k "$outputAudioFile.fixed.m4b"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to re-encode audio for $outputAudioFile"
}
#replace the original audio file with the fixed one
Move-Item -Path "$outputAudioFile.fixed.m4b" -Destination "$outputAudioFile" -Force

