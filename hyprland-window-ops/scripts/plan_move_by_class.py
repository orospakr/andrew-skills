#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import sys
from typing import Dict, List

from parse_hypr_clients import parse_clients


def normalize_address(addr: str) -> str:
    addr = addr.strip()
    if addr.startswith("0x"):
        return addr.lower()
    if re.fullmatch(r"[0-9a-fA-F]+", addr):
        return "0x" + addr.lower()
    return addr


def select_windows(windows: List[Dict[str, object]], klass: str) -> List[Dict[str, object]]:
    return [w for w in windows if str(w.get("class", "")) == klass]


def build_cmd(workspace: int, address: str) -> str:
    return f"movetoworkspacesilent {workspace},address:{normalize_address(address)}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Plan Hyprland move commands by window class")
    parser.add_argument("--input", help="Path to clients text file (defaults to stdin)")
    parser.add_argument("--class", dest="klass", required=True, help="Exact class match")
    parser.add_argument("--workspace", type=int, required=True, help="Target workspace number")
    parser.add_argument("--execute", action="store_true", help="Execute via hyprctl dispatch")
    parser.add_argument("--json", action="store_true", help="Output JSON plan")
    args = parser.parse_args()

    if args.input:
        with open(args.input, "r", encoding="utf-8") as f:
            text = f.read()
    else:
        text = sys.stdin.read()

    windows = parse_clients(text)
    targets = select_windows(windows, args.klass)

    plan = []
    for w in targets:
        address = str(w.get("address", ""))
        current_ws = w.get("workspace")
        cmd = build_cmd(args.workspace, address)
        plan.append(
            {
                "address": normalize_address(address),
                "class": w.get("class", ""),
                "title": w.get("title", ""),
                "workspace": current_ws,
                "target_workspace": args.workspace,
                "already_compliant": current_ws == args.workspace,
                "dispatch": cmd,
            }
        )

    if args.execute:
        for item in plan:
            subprocess.run(["hyprctl", "dispatch", *item["dispatch"].split(" ", 1)], check=False)

    if args.json:
        print(json.dumps(plan, indent=2, sort_keys=True))
    else:
        for item in plan:
            print(item["dispatch"])

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
