#!/usr/bin/env python3
"""Convert luacov.stats.out to Cobertura XML coverage report.

Reads the standard luacov stats file and produces a minimal Cobertura
XML report.  Blank lines and comment lines (starting with '#') are
excluded from the "executable" line count, matching busted's default
behaviour.

Usage: python3 luacov-to-cobertura.py [luacov.stats.out] [coverage.xml]
"""

import sys
import os
import xml.etree.ElementTree as ET
from xml.dom import minidom


def parse_luacov_stats(path):
    """Parse luacov.stats.out into {filename: {line_num: hit_count}}."""
    files = {}
    if not os.path.isfile(path):
        print(f"ERROR: {path} not found", file=sys.stderr)
        return files

    current_file = None
    with open(path, "r") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("#"):
                # Comment header — skip
                continue
            if ":" not in line:
                # Start of a new file section: "filepath:"
                current_file = line.rstrip(":")
                files[current_file] = {}
            else:
                # line_num:hits
                parts = line.split(":", 1)
                try:
                    line_num = int(parts[0])
                    hits = int(parts[1])
                except ValueError:
                    continue
                if current_file is not None:
                    files[current_file][line_num] = hits
    return files


def generate_cobertura(files, output_path):
    """Generate Cobertura XML from parsed stats."""
    coverage = ET.Element("coverage")
    coverage.set("line-rate", "0")
    coverage.set("branch-rate", "0")
    coverage.set("version", "1.9")
    coverage.set("timestamp", "")

    sources = ET.SubElement(coverage, "sources")
    cwd = os.getcwd()
    ET.SubElement(sources, "source").text = cwd

    packages_elem = ET.SubElement(coverage, "packages")
    package = ET.SubElement(packages_elem, "package")
    package.set("name", "booklore-koreader-plugin")
    classes = ET.SubElement(package, "classes")

    total_lines = 0
    total_covered = 0

    for filepath in sorted(files.keys()):
        file_lines = files[filepath]
        if not file_lines:
            continue

        max_line = max(file_lines.keys())
        # Count executable lines: all lines in file_lines dict
        executable = len(file_lines)
        covered = sum(1 for hits in file_lines.values() if hits > 0)
        total_lines += executable
        total_covered += covered

        line_rate = (covered / executable) if executable > 0 else 0

        cls = ET.SubElement(classes, "class")
        cls.set("name", os.path.basename(filepath))
        cls.set("filename", filepath)
        cls.set("line-rate", f"{line_rate:.4f}")
        cls.set("branch-rate", "0")
        cls.set("complexity", "0")

        methods = ET.SubElement(cls, "methods")
        lines_elem = ET.SubElement(cls, "lines")

        for line_num in sorted(file_lines.keys()):
            hits = file_lines[line_num]
            line_el = ET.SubElement(lines_elem, "line")
            line_el.set("number", str(line_num))
            line_el.set("hits", str(hits))
            line_el.set("branch", "false")

    overall_rate = (total_covered / total_lines) if total_lines > 0 else 0
    coverage.set("line-rate", f"{overall_rate:.4f}")
    coverage.set("lines-covered", str(total_covered))
    coverage.set("lines-valid", str(total_lines))

    xml_str = ET.tostring(coverage, encoding="unicode")
    pretty = minidom.parseString(xml_str).toprettyxml(indent="  ")

    with open(output_path, "w") as fh:
        fh.write(pretty)

    print(f"OK  coverage.xml written ({total_lines} lines, {total_covered} covered)")


def main():
    stats_path = sys.argv[1] if len(sys.argv) > 1 else "luacov.stats.out"
    output_path = sys.argv[2] if len(sys.argv) > 2 else "coverage.xml"

    files = parse_luacov_stats(stats_path)
    if not files:
        sys.exit(1)

    generate_cobertura(files, output_path)


if __name__ == "__main__":
    main()
