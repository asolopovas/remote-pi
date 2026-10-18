#!/usr/bin/env python3
"""Check source-checkout Markdown links, anchors, navigation and copied prose."""

import argparse
import html
import re
import subprocess
import sys
import unicodedata
import unittest
from collections import defaultdict
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def prose_lines(text):
    """Ignore fenced examples and initial YAML metadata, retaining line numbers."""
    fence = None
    frontmatter = text.startswith("---\n")
    for number, line in enumerate(text.splitlines(), 1):
        if frontmatter:
            if number > 1 and line.strip() == "---":
                frontmatter = False
            continue
        match = re.match(r"^\s{0,3}(`{3,}|~{3,})(.*)$", line)
        if match:
            marker, rest = match.groups()
            if fence is None:
                fence = marker
            elif marker[0] == fence[0] and len(marker) >= len(fence) and not rest.strip():
                fence = None
            continue
        if fence is None:
            yield number, line


def plain_inline(text):
    return re.sub(r"(`+).*?\1", "", text)


def slug(text):
    text = html.unescape(re.sub(r"<[^>]*>", "", text)).lower()
    text = "".join(
        char for char in text
        if char in " _-" or unicodedata.category(char)[0] in "LNM"
    )
    return text.replace(" ", "-")


def anchors(text):
    found, counts = set(), defaultdict(int)
    lines = list(prose_lines(text))
    for index, (_, line) in enumerate(lines):
        heading = re.match(r"^ {0,3}#{1,6}\s+(.+?)(?:\s+#+)?\s*$", line)
        title = heading.group(1) if heading else None
        if (title is None and index + 1 < len(lines) and line.strip()
                and re.fullmatch(r"\s{0,3}(?:=+|-+)\s*", lines[index + 1][1])):
            title = line.strip()
        if title is not None:
            base = slug(title)
            suffix = counts[base]
            found.add(base if suffix == 0 else f"{base}-{suffix}")
            counts[base] += 1
        found.update(re.findall(r'\b(?:id|name)=["\']([^"\']+)["\']', line))
    return found


def links(text):
    lines = list(prose_lines(text))
    definitions = {}
    for number, line in lines:
        match = re.match(r"^\s{0,3}\[([^]]+)\]:\s*<?([^\s>]+)>?", line)
        if match:
            definitions[match.group(1).casefold()] = match.group(2)
            yield number, match.group(2)
    for number, line in lines:
        if re.match(r"^\s{0,3}\[[^]]+\]:", line):
            continue
        line = plain_inline(line)
        for match in re.finditer(r"\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+[^)]*)?\)", line):
            yield number, match.group(1) or match.group(2)
        for match in re.finditer(r"\[([^]\n]+)\]\[([^]\n]*)\]", line):
            key = (match.group(2) or match.group(1)).casefold()
            yield number, definitions.get(key, f"missing-reference:{key}")
        # Shortcut reference links are recognized only when explicitly defined.
        for match in re.finditer(r"(?<!\])\[([^]\n]+)\](?![\[(])", line):
            key = match.group(1).casefold()
            if key in definitions:
                yield number, definitions[key]
        for match in re.finditer(r'\b(?:href|src)=["\']([^"\']+)["\']', line):
            yield number, html.unescape(match.group(1))


def reachable(graph, start):
    seen, pending = set(), [start]
    while pending:
        item = pending.pop()
        if item not in seen:
            seen.add(item)
            pending.extend(graph.get(item, set()) - seen)
    return seen


def check(root):
    output = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
    )
    files = {root / name.decode() for name in output.split(b"\0") if name}
    docs = {path for path in files if path.suffix == ".md" and path.is_file()}
    texts = {path: path.read_text(encoding="utf-8") for path in docs}
    ids = {path: anchors(text) for path, text in texts.items()}
    graph = {path: set() for path in docs}
    errors, references = [], 0
    if any(path.parent == root / '.github/workflows' and path.suffix in {'.yml', '.yaml'}
           for path in files):
        errors.append('GitHub workflows are disabled by project policy; run checks locally.')
    for source, text in texts.items():
        for line, url in links(text):
            location = f"{source.relative_to(root)}:{line}"
            parts = urlsplit(url)
            if parts.scheme == "missing-reference":
                errors.append(f"{location}: undefined reference {parts.path}")
                continue
            if parts.scheme or parts.netloc:
                if parts.scheme.lower() in {"javascript", "vbscript"}:
                    errors.append(f"{location}: unsafe link scheme")
                continue  # Remote URLs are deliberately not fetched.
            references += 1
            target = (root if parts.path.startswith("/") else source.parent)
            target = (target / unquote(parts.path).lstrip("/")).resolve() if parts.path else source
            if not target.is_relative_to(root) or not target.exists():
                errors.append(f"{location}: missing/outside-checkout target {url}")
                continue
            if target.is_dir():
                candidate = target / "README.md"
                if candidate in docs:
                    target = candidate
                elif parts.fragment:
                    errors.append(f"{location}: fragment on directory without README: {url}")
                    continue
                else:
                    continue
            if target not in files:
                errors.append(f"{location}: target is ignored/untracked publication state: {url}")
                continue
            if target in docs:
                graph[source].add(target)
                if parts.fragment and unquote(parts.fragment) not in ids[target]:
                    errors.append(f"{location}: missing heading #{parts.fragment} in {target.relative_to(root)}")
    entry = root / "README.md"
    forward = reachable(graph, entry)
    reverse = {path: set() for path in docs}
    for source, targets in graph.items():
        for target in targets:
            reverse[target].add(source)
    for path in sorted(docs - forward):
        errors.append(f"Orphan guide: {path.relative_to(root)} (not reachable from README.md)")
    for path in sorted(docs - reachable(reverse, entry)):
        errors.append(f"No route back to project index: {path.relative_to(root)}")
    for directory in root.iterdir():
        if (directory.is_dir() and not directory.name.startswith(".")
                and directory / "README.md" not in forward
                and any((directory / manifest).exists()
                        for manifest in ("Cargo.toml", "package.json", "pubspec.yaml"))):
            errors.append(f"Project has no discoverable guide: {directory.name}")
    paragraphs = defaultdict(set)
    for path, text in texts.items():
        body = "\n".join(line for _, line in prose_lines(text))
        for paragraph in re.split(r"\n\s*\n", body):
            if paragraph.lstrip().startswith(("#", "|", "<!--")):
                continue
            normalized = re.sub(r"\]\([^)]*\)", "]", paragraph)
            normalized = " ".join(normalized.split())
            if len(normalized.split()) >= 35:
                paragraphs[normalized].add(path)
    for paragraph, owners in paragraphs.items():
        if len(owners) > 1:
            names = ", ".join(str(p.relative_to(root)) for p in sorted(owners))
            errors.append(f"Copied prose ({len(paragraph.split())} words): {names}")
    print(f"Checked {len(docs)} Markdown files and {references} local links; "
          f"{len(forward & docs)}/{len(docs)} guides reachable from the project index.")
    for error in errors:
        print(error)
    print("Remote URLs and semantic duplication require manual review.")
    return 1 if errors else 0


class ParserTests(unittest.TestCase):
    def test_examples_are_not_links(self):
        self.assertEqual(list(links("```md\n[x](missing)\n```\n`[x](example)`")), [])

    def test_inline_code_in_label_keeps_link(self):
        self.assertEqual(list(links("[`source`](README.md#topic)")), [(1, "README.md#topic")])

    def test_long_fence_and_metadata(self):
        text = "---\nx: [x](ignored)\n---\n````md\n```\n[x](ignored)\n````\n[x](ok)"
        self.assertEqual(list(links(text)), [(8, "ok")])

    def test_headings_and_duplicates(self):
        self.assertEqual(anchors("# Café / Tools\n## Café / Tools\n```\n# hidden\n```"),
                         {"café--tools", "café--tools-1"})

    def test_references_and_html(self):
        text = '[target]: README.md\n[x][target]\n<a href="README.md#top">go</a>'
        self.assertEqual([url for _, url in links(text)],
                         ["README.md", "README.md", "README.md#top"])

    def test_setext_heading(self):
        self.assertIn("details", anchors("Details\n-------"))

    def test_graph_direction(self):
        graph = {"root": {"child"}, "child": set()}
        self.assertEqual(reachable(graph, "root"), {"root", "child"})
        self.assertEqual(reachable(graph, "child"), {"child"})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        unittest.main(argv=[sys.argv[0]])
    else:
        sys.exit(check(ROOT))
