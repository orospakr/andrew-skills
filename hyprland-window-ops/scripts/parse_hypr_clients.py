#!/usr/bin/env python3
import argparse
import json
import re
import sys
from typing import Dict, List

WINDOW_RE = re.compile(r"^Window\s+([0-9a-fA-Fx]+)\s+->\s*(.*?):\s*$")
KV_RE = re.compile(r"^\s*([a-zA-Z][\w]*):\s*(.*)\s*$")


def normalize_address(addr: str) -> str:
    addr = addr.strip()
    if addr.startswith("0x"):
        return addr.lower()
    if re.fullmatch(r"[0-9a-fA-F]+", addr):
        return "0x" + addr.lower()
    return addr


def parse_clients(text: str) -> List[Dict[str, object]]:
    windows: List[Dict[str, object]] = []
    current: Dict[str, object] = {}

    for line in text.splitlines():
        m = WINDOW_RE.match(line)
        if m:
            if current:
                windows.append(current)
            raw_addr, headline = m.groups()
            current = {
                "address": normalize_address(raw_addr),
                "headline": headline,
            }
            continue

        if not current:
            continue

        kvm = KV_RE.match(line)
        if not kvm:
            continue

        key, value = kvm.groups()
        key = key.strip()
        value = value.strip()

        if key == "workspace":
            # Format: "3 (3)"
            ws = value.split(" ", 1)[0]
            try:
                current["workspace"] = int(ws)
            except ValueError:
                current["workspace"] = ws
        elif key in {"mapped", "hidden", "floating", "pinned", "fullscreen"}:
            current[key] = value == "1"
        else:
            current[key] = value

    if current:
        windows.append(current)

    return windows


def main() -> int:
    parser = argparse.ArgumentParser(description="Parse Hyprland clients output to JSON")
    parser.add_argument("--input", help="Path to clients text file (defaults to stdin)")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON")
    args = parser.parse_args()

    if args.input:
        with open(args.input, "r", encoding="utf-8") as f:
            text = f.read()
    else:
        text = sys.stdin.read()

    result = parse_clients(text)
    if args.pretty:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
