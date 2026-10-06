#!/usr/bin/env python3
"""Check the public payload without printing any secret value."""
import argparse
import base64
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import zipfile

PRIVATE_MARKER = re.compile(rb"(?m)^-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----")
GITHUB_TOKEN = re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})")
SENSITIVE_SUFFIXES = (".p12", ".pfx", ".pem", ".key", ".keychain", ".keychain-db")


def check_payload(name, data, private_values):
    if PRIVATE_MARKER.search(data) or GITHUB_TOKEN.search(data) or any(value in data for value in private_values):
        raise ValueError(f"Sensitive material detected in {name}; contents were not logged.")


def verify(archive, private_key_file=None, source=False):
    private_values = []
    if private_key_file:
        encoded = Path(private_key_file).read_bytes().strip()
        decoded = base64.b64decode(encoded, validate=True)
        if len(decoded) != 32:
            raise ValueError("Invalid signing-key format; contents were not logged.")
        private_values = [encoded, decoded]
    with zipfile.ZipFile(archive) as bundle:
        for entry in bundle.infolist():
            name = entry.filename
            relative = PurePosixPath(name)
            if relative.is_absolute() or ".." in relative.parts or relative.parts[0] != "LocalWrite.app":
                raise ValueError("Archive contains an unexpected path.")
            if name.lower().endswith(SENSITIVE_SUFFIXES) or relative.name.startswith(".env"):
                raise ValueError(f"Unexpected credential file in archive: {name}")
            if not entry.is_dir():
                check_payload(name, bundle.read(entry), private_values)
        info = plistlib.loads(bundle.read("LocalWrite.app/Contents/Info.plist"))
        required = {
            "CFBundleIdentifier": "com.localwrite.mac",
            "SUFeedURL": "https://raw.githubusercontent.com/varvand/LocalWrite/updates/appcast.xml",
            "SUVerifyUpdateBeforeExtraction": True,
            "SURequireSignedFeed": True,
            "SUSendProfileInfo": False,
        }
        if any(info.get(key) != value for key, value in required.items()):
            raise ValueError("Missing or incorrect secure updater configuration.")
        if len(base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)) != 32:
            raise ValueError("Invalid public verification key.")
    if source:
        tracked = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"])
        for filename in tracked.split(b"\0"):
            if filename:
                file = Path(os.fsdecode(filename))
                if file.is_file():
                    check_payload(str(file), file.read_bytes(), private_values)
    print("Public update archive and source checks passed; no private signing material detected.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("archive")
    parser.add_argument("--private-key-file")
    parser.add_argument("--source", action="store_true")
    args = parser.parse_args()
    try:
        verify(args.archive, args.private_key_file, args.source)
    except Exception as error:
        raise SystemExit(str(error))
