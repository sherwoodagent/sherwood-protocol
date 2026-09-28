#!/usr/bin/env python3
"""Mechanical comment strip for src/**/*.sol (SHE-253, PR 0).

(a) delete every contiguous comment block longer than six lines that precedes
    an internal/private function or sits inside a function body;
(b) delete every comment line matching the history/audit-trail regex.
Bytecode must be byte-identical afterwards; the compare script checks that.
"""
import re, sys, pathlib

HIST = re.compile(r"SHE-[0-9]|issue #[0-9]|PR #[0-9]|pashov|finding #[0-9]|[Pp]roven on|measured 20[0-9]{2}-")
LINE_COMMENT = re.compile(r"^\s*(///|//)")
BLOCK_OPEN = re.compile(r"^\s*/\*")
FUNC = re.compile(r"^\s*function\b")

def is_comment_only(lines, i):
    """Return number of lines of the comment element starting at i, or 0."""
    l = lines[i]
    if LINE_COMMENT.match(l):
        return 1
    if BLOCK_OPEN.match(l):
        j = i
        while j < len(lines) and "*/" not in lines[j]:
            j += 1
        if j >= len(lines):
            return 0
        # block comment must be alone on its closing line
        if lines[j].split("*/", 1)[1].strip() != "":
            return 0
        return j - i + 1
    return 0

def strip_code_comments(l):
    """Crude: remove // and /* */ comment text on a single line, and string contents."""
    l = re.sub(r'"(?:\\.|[^"\\])*"', '""', l)
    l = re.sub(r"'(?:\\.|[^'\\])*'", "''", l)
    l = re.sub(r"/\*.*?\*/", "", l)
    l = re.sub(r"//.*$", "", l)
    return l

def header_visibility(lines, i):
    """From a `function` line, read until `{` or `;` and report internal/private."""
    buf = ""
    j = i
    while j < len(lines):
        buf += strip_code_comments(lines[j]) + " "
        if "{" in buf or ";" in buf:
            break
        j += 1
    head = buf.split("{")[0].split(";")[0]
    return bool(re.search(r"\b(internal|private)\b", head))

TAG = re.compile(r"^\s*(///|//|/\*+|\*)\s*@\w+")
CONT = re.compile(r"^\s*(///|//|\*)(?!\s*@)")

def drop_hist_lines(block):
    """Rule (b). A deleted line that opens a natspec tag takes its untagged
    continuation lines with it, so the text cannot fold into the previous tag."""
    kept = []
    i = 0
    while i < len(block):
        l = block[i]
        if HIST.search(l):
            i += 1
            if TAG.match(l):
                while i < len(block) and CONT.match(block[i]) and not HIST.search(block[i]) and block[i].strip() not in ("*/",):
                    i += 1
            continue
        kept.append(l)
        i += 1
    return kept

def process(path):
    src = path.read_text().split("\n")
    out = []
    i = 0
    depth = 0          # brace depth after stripping comments/strings
    in_block = False   # inside a multi-line /* */ that is NOT comment-only (rare)
    func_depths = []   # brace depth at which each open function body started
    removed_blocks = 0
    removed_lines = 0
    n = len(src)
    while i < n:
        span = 0
        while i + span < n:
            e = is_comment_only(src, i + span)
            if not e:
                break
            span += e
        if span:
            block = src[i:i+span]
            # determine what follows the block (skip blank lines)
            k = i + span
            while k < n and src[k].strip() == "":
                k += 1
            inside_fn = bool(func_depths)
            precedes_internal = k < n and FUNC.match(src[k]) and header_visibility(src, k)
            if span > 6 and (inside_fn or precedes_internal):
                removed_blocks += 1
                removed_lines += span
                i += span
                continue
            kept = drop_hist_lines(block)
            removed_lines += span - len(kept)
            out.extend(kept)
            i += span
            continue
        l = src[i]
        code = strip_code_comments(l)
        if FUNC.match(l):
            j = i; buf = ""
            while j < n:
                buf += strip_code_comments(src[j]) + " "
                if "{" in buf or ";" in buf:
                    break
                j += 1
            first_brace = buf.find("{"); first_semi = buf.find(";")
            if first_brace != -1 and (first_semi == -1 or first_brace < first_semi):
                func_depths.append(depth)
        opens = code.count("{"); closes = code.count("}")
        depth += opens - closes
        if closes:
            while func_depths and depth <= func_depths[-1]:
                func_depths.pop()
        out.append(l)
        i += 1
    if out != src:
        path.write_text("\n".join(out))
    return removed_blocks, removed_lines

def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "src")
    tb = tl = 0
    for p in sorted(root.rglob("*.sol")):
        b, l = process(p)
        if b or l:
            print(f"{p}: blocks={b} lines={l}")
        tb += b; tl += l
    print(f"TOTAL blocks={tb} lines={tl}")

if __name__ == "__main__":
    main()
