"""Convert a .txt file into a single-chapter .epub using pypub3."""
import sys
import os

import pypub


def main():
    if len(sys.argv) != 3:
        print("Usage: python convert_txt_to_epub.py <input.txt> <output.epub>", file=sys.stderr)
        sys.exit(1)

    text_file, output_file = sys.argv[1], sys.argv[2]
    title = os.path.splitext(os.path.basename(text_file))[0]

    epub = pypub.Epub(title)
    chapter = pypub.create_chapter_from_file(text_file, title=title)
    epub.add_chapter(chapter)
    epub.create(output_file)


if __name__ == "__main__":
    main()
