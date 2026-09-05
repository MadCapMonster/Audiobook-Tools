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

---

# Other scripts in this repo

## convert_txt_to_epub.py

Helper used internally by `CreateAudioBook.ps1` / `createAudioBookfromUrl.ps1`. Wraps `pypub3` to turn a single `.txt` file into a single-chapter `.epub`.

```
python convert_txt_to_epub.py <input.txt> <output.epub>
```

## createAudioBookfromUrl.ps1 / createAudioBook copy.ps1

Earlier, one-off versions of `CreateAudioBook.ps1` kept for reference. `createAudioBookfromUrl.ps1` hard-codes the "Author's Note" trimming logic instead of using the `handlers\` parser system, and neither supports the generic `-Url` download step. Prefer `CreateAudioBook.ps1` for new conversions.

## Convert-Audiobook.ps1

Batch-converts folders of chaptered MP3s (e.g. an audiobook ripped as one MP3 per chapter) into a single M4B per folder.

1. Recursively scans `-Root` for `*.mp3` files and groups them by containing folder — one output book per folder, at any nesting depth (e.g. `X:\Author\Book\*.mp3`).
2. Skips a folder if it already contains an `.m4b`.
3. Builds a `chapters.txt` from the MP3 filenames (in sorted order).
4. Extracts cover art from the first MP3 with FFmpeg.
5. Concatenates the MP3s into one AAC-encoded `.m4b` with FFmpeg.
6. Embeds title, chapters, and cover art with `AtomicParsley`.
7. Deletes the source MP3s once the M4B is built.

```powershell
.\Convert-Audiobook.ps1 -Root "X:\Audiobooks"
```

**Requires:** `ffmpeg` and `AtomicParsley` on `PATH`.

## getFolders.ps1

Read-only report: recursively scans `-Root` and writes a CSV (`-OutCsv`, default `folders-with-mp3.csv`) listing every folder that contains MP3 files along with the MP3 count in that folder. Useful for previewing what `Convert-Audiobook.ps1` would process before running it. Shows a progress bar and a final summary (folder count, total MP3s, elapsed time).

```powershell
.\getFolders.ps1 -Root "X:\Audiobooks" -OutCsv "report.csv"
```

## sortAudioBooks.ps1

Automates filing audiobooks dropped into an [Audiobookshelf](https://www.audiobookshelf.org/) "drop" folder into a proper `Author\Series\Title` structure.

1. Removes helper files (`.nfo`, `.jpg`, `.sfv`, `.txt`) from `-DropRoot`.
2. Triggers an Audiobookshelf library scan and waits for new items to be discovered.
3. For each discovered item, reads its author/series/title metadata from the ABS API.
4. Builds the destination path under `-LibraryRoot` and moves the book folder there (comparing file hashes if the destination already exists, so it can safely skip duplicates or replace stale copies).
5. Removes any empty folders left behind in the drop root and runs a final ABS scan.

```powershell
$env:ABS_API_KEY = "your-audiobookshelf-api-key"
.\sortAudioBooks.ps1 -DropRoot "X:\drop" -LibraryRoot "X:\" -ServerUrl "http://192.168.68.158:13378"
```

Pass `-DryRun` to preview every move/delete without changing anything.

**Requires:** an Audiobookshelf server and API key. Set the key via `$env:ABS_API_KEY` — do not hard-code it in the script or command line.

## api.ps1

Minimal smoke test that confirms an Audiobookshelf server is reachable and the API key is valid. Reads the key from `$env:ABS_API_KEY`.

```powershell
$env:ABS_API_KEY = "your-audiobookshelf-api-key"
.\api.ps1
```

## Security note

`api.ps1` and `sortAudioBooks.ps1` previously had real Audiobookshelf API keys hard-coded as defaults. Both now read the key from `$env:ABS_API_KEY` (or the `-ApiKey` parameter) instead. If you have committed keys in your git history, rotate them on the Audiobookshelf server, since they remain readable in past commits.

