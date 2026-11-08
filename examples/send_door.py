#!/usr/bin/env python3
"""A simple send door for gvoice.

gvoice hands every text to a door before it goes out. The door decides, sends the text with
"gvoice send --direct" when it is allowed, and prints one line of JSON:
{"decision": "sent" or "blocked", "reason_code": "..."}

This door only lets texts go to numbers listed in ~/.config/gvoice/allowed_numbers.txt,
one number per line, written any common way. Copy it, then add your own rules:

    mkdir -p ~/.config/gvoice
    cp examples/send_door.py ~/.config/gvoice/send_door
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

ALLOWED = os.path.expanduser("~/.config/gvoice/allowed_numbers.txt")


def ten_digits(number):
    return re.sub(r"\D", "", number)[-10:]


def answer(decision, reason):
    print(json.dumps({"decision": decision, "reason_code": reason}))
    sys.exit(0)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--phone", required=True)
    p.add_argument("--text", required=True)
    p.add_argument("--key", default="")
    p.add_argument("--source", default="")
    a = p.parse_args()

    try:
        with open(ALLOWED) as f:
            allowed = {ten_digits(line) for line in f if line.strip() and not line.startswith("#")}
    except FileNotFoundError:
        answer("blocked", "no_allowed_numbers_file")
    if ten_digits(a.phone) not in allowed:
        answer("blocked", "number_not_allowed")

    gvoice = shutil.which("gvoice") or "/opt/homebrew/bin/gvoice"
    cmd = [gvoice, "send", "--to", a.phone, "--text", a.text, "--direct"]
    if a.key:
        cmd += ["--key", a.key]
    r = subprocess.run(cmd, capture_output=True, text=True)
    try:
        out = json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        answer("blocked", "send_error")
    if out.get("ok"):
        answer("sent", "allowed")
    code = (out.get("error") or {}).get("code", "send_error")
    answer("uncertain" if code == "SEND_UNCERTAIN" else "blocked", code.lower())


if __name__ == "__main__":
    main()
