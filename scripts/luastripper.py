import argparse
from pathlib import Path


def read_long_bracket(text: str, start: int):
    """Detect Lua long bracket syntax:
      [[ ... ]]
      [=[ ... ]=]
      [==[ ... ]==]
    Returns (opening_length, equals_count) or None.
    """
    if start >= len(text) or text[start] != "[":
        return None

    i = start + 1
    equals_count = 0

    while i < len(text) and text[i] == "=":
        equals_count += 1
        i += 1

    if i < len(text) and text[i] == "[":
        return i - start + 1, equals_count

    return None


def find_long_bracket_end(text: str, start: int, equals_count: int):
    closing = "]" + ("=" * equals_count) + "]"
    end = text.find(closing, start)

    if end == -1:
        return len(text)

    return end + len(closing)


def remove_empty_lines(source: str) -> str:
    lines = source.splitlines()

    non_empty_lines = [line for line in lines if line.strip()]

    if source.endswith("\n") and non_empty_lines:
        return "\n".join(non_empty_lines) + "\n"

    return "\n".join(non_empty_lines)


def strip_lua_comments(source: str, remove_blank_lines: bool = False) -> str:
    result = []
    i = 0
    n = len(source)

    while i < n:
        char = source[i]

        # Handle normal quoted strings
        if char in ("'", '"'):
            quote = char
            result.append(char)
            i += 1

            while i < n:
                result.append(source[i])

                if source[i] == "\\":
                    i += 1
                    if i < n:
                        result.append(source[i])
                elif source[i] == quote:
                    i += 1
                    break

                i += 1

            continue

        # Handle Lua long strings: [[...]], [=[...]=], etc.
        if char == "[":
            long_bracket = read_long_bracket(source, i)

            if long_bracket:
                opening_length, equals_count = long_bracket
                end = find_long_bracket_end(
                    source,
                    i + opening_length,
                    equals_count,
                )
                result.append(source[i:end])
                i = end
                continue

        # Handle comments
        if char == "-" and i + 1 < n and source[i + 1] == "-":
            comment_start = i + 2

            # Multi-line comment: --[[...]] or --[=[...]=]
            if comment_start < n and source[comment_start] == "[":
                long_bracket = read_long_bracket(source, comment_start)

                if long_bracket:
                    opening_length, equals_count = long_bracket
                    end = find_long_bracket_end(
                        source,
                        comment_start + opening_length,
                        equals_count,
                    )

                    # Preserve line breaks for now.
                    # Empty lines can be removed afterward.
                    removed = source[i:end]
                    result.append("\n" * removed.count("\n"))

                    i = end
                    continue

            # Single-line comment
            line_end = source.find("\n", i)

            if line_end == -1:
                break

            result.append("\n")
            i = line_end + 1
            continue

        result.append(char)
        i += 1

    stripped = "".join(result)

    if remove_blank_lines:
        stripped = remove_empty_lines(stripped)

    return stripped


def process_file(path: Path, in_place: bool, suffix: str, remove_blank_lines: bool):
    original = path.read_text(encoding="utf-8")
    stripped = strip_lua_comments(
        original,
        remove_blank_lines=remove_blank_lines,
    )

    if stripped == original:
        return False

    if in_place:
        path.write_text(stripped, encoding="utf-8")
    else:
        output_path = path.with_name(path.name + suffix)
        output_path.write_text(stripped, encoding="utf-8")

    return True


def main():
    parser = argparse.ArgumentParser(
        description="Remove single-line and multi-line comments from Lua files.",
    )
    parser.add_argument(
        "directory",
        type=Path,
        help="Directory containing Lua files.",
    )
    parser.add_argument(
        "--in-place",
        action="store_true",
        help="Overwrite Lua files directly.",
    )
    parser.add_argument(
        "--suffix",
        default=".stripped",
        help="Suffix for output files when not using --in-place.",
    )
    parser.add_argument(
        "--remove-empty-lines",
        action="store_true",
        help="Remove empty lines after comments are stripped.",
    )

    args = parser.parse_args()

    if not args.directory.is_dir():
        raise SystemExit(f"Not a directory: {args.directory}")

    changed = 0

    for lua_file in args.directory.rglob("*.lua"):
        if process_file(
            lua_file,
            args.in_place,
            args.suffix,
            args.remove_empty_lines,
        ):
            changed += 1
            print(f"Updated: {lua_file}")

    print(f"Done. Files changed: {changed}")


if __name__ == "__main__":
    main()
