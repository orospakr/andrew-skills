#!/usr/bin/env python3
import argparse
import sys


def extract_terminal_command(text: str) -> str:
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "description: Terminal":
            for j in range(i + 1, min(i + 8, len(lines))):
                candidate = lines[j].strip()
                if candidate.startswith("arg:"):
                    return candidate[len("arg:") :].strip()
    return ""


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract terminal launch command from Hyprland binds output")
    parser.add_argument("--input", help="Path to binds text file (defaults to stdin)")
    args = parser.parse_args()

    if args.input:
        with open(args.input, "r", encoding="utf-8") as f:
            text = f.read()
    else:
        text = sys.stdin.read()

    command = extract_terminal_command(text)
    if not command:
        print("No terminal bind found", file=sys.stderr)
        return 1

    print(command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
