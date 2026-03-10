#!/usr/bin/env python3
import argparse


def main() -> int:
    parser = argparse.ArgumentParser(description="Build Hyprland exec dispatch args for a target workspace")
    parser.add_argument("--workspace", type=int, required=True, help="Target workspace number")
    parser.add_argument("--cmd", required=True, help="Command to execute")
    args = parser.parse_args()

    print(f"exec [workspace {args.workspace}] {args.cmd}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
