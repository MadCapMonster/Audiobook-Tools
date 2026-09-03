# CreateAudioBook.ps1

Turns a text file (or a web page URL) into an M4B audiobook using [audiblez](https://github.com/santinic/audiblez) for text-to-speech and FFmpeg for final packaging.

## What it does, step by step

1. Makes sure FFmpeg is installed (installs it via `winget` if missing).
2. Makes sure Python 3.11 is installed (installs it via `winget` if missing).
3. Creates a Python virtual environment (`.\audiblez-env` by default) if one doesn't already exist.
4. Installs `audiblez`, `pillow`, `wxpython`, `pypub3` into the venv.
5. Checks whether PyTorch can use your NVIDIA GPU (CUDA). If not, installs the CUDA-enabled build.
6. If `-Url` is given: downloads the page, strips it down to plain text, and runs it through a per-website "parser" (see below) to remove junk like author's notes or comment sections.
7. Converts the resulting text file to an EPUB.
8. Runs `audiblez` to generate the M4B audiobook (using the GPU if available).
9. Re-encodes the audio to AAC so the M4B plays correctly in standard players (audiblez's raw output uses PCM audio, which isn't supported by the M4B/iPod container).

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-Url` | *(none)* | Optional. A web page to download and convert instead of using an existing local text file. |
| `-VenvPath` | `.\audiblez-env` | Where the Python virtual environment lives. Reused if it already exists. |
| `-textFile` | `Beginnings.txt` | The source text file. If `-Url` is given, the downloaded/cleaned text is written here first. |
| `-outputBaseFolder` | `C:\audiblez\output-audio` | Root folder for all generated output. Each book gets its own subfolder named after `-textFile`. |
| `-voice` | `af_bella` | The audiblez narration voice to use. |

## Usage examples

Convert an existing local text file:

```powershell
.\CreateAudioBook.ps1 -textFile "Beginnings.txt"
```

Download a web page and convert it directly:

```powershell
.\CreateAudioBook.ps1 -Url "https://parahumans.wordpress.com/2011/06/11/1-1/" -textFile "Worm-1.1.txt"
```

Use a different voice and output location:

```powershell
.\CreateAudioBook.ps1 -textFile "MyBook.txt" -voice "am_adam" -outputBaseFolder "D:\Audiobooks"
```

Rerun safely: the script skips recreating the venv/torch install if they're already set up, and overwrites any existing EPUB/M4B for the same book.

## Website parsers (`handlers\` folder)

When you use `-Url`, the downloaded page's HTML is converted to plain text, then passed through a small PowerShell script ("parser") chosen by the website's host name (e.g. `parahumans.wordpress.com`).

- If a parser file already exists for that host (`handlers\<host>.ps1`), it's used.
- If not, one is automatically created by copying [handlers/default.ps1](handlers/default.ps1), so you can edit it later just for that site.

Each parser defines one function:

```powershell
function Invoke-ContentCleanup {
    param([string]$Content, [string]$BaseName)
    # ... modify $Content ...
    return $Content
}
```

- `$Content` – the full plain-text page content.
- `$BaseName` – the name of the book/chapter being created (from `-textFile`), handy for inserting text like `"End of $BaseName"`.

The default template includes commented-out examples for common cleanup tasks (removing a "Leave a Reply" comments section, cutting an "Author's Note", stripping "previous/next chapter" links) — uncomment and adjust the marker text to match the actual site.

### Use cases for custom parsers

- **Web serial with an author's note after each chapter** – cut everything from the note marker onward (see [handlers/parahumans.wordpress.com.ps1](handlers/parahumans.wordpress.com.ps1)).
- **Blog with a comments section** – cut everything from "Leave a Reply" / "Comments" onward.
- **Site with repeated navigation text** – remove "Previous Chapter / Next Chapter" links so they aren't read aloud.
- **Site with ads or related-post boilerplate** – strip known boilerplate phrases with `-replace`.

## Requirements

- Windows PowerShell with `winget` available (used to auto-install Python 3.11 and FFmpeg if missing).
- An NVIDIA GPU is optional but recommended — the script detects CUDA support automatically and falls back to CPU if unavailable.
