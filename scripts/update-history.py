"""Authenticate historical inputs before Sparkle can extract or sign them."""
import argparse
import base64
from dataclasses import dataclass
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

REPOSITORY = "varvand/LocalWrite"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
PREFIX = b"<!-- sparkle-signatures:\n"
MAX_FEED_BYTES = 1024 * 1024
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
VERSION = r"(?:0|[1-9][0-9]{0,8})(?:\.(?:0|[1-9][0-9]{0,8})){0,2}"


@dataclass(frozen=True)
class Release:
    version: str
    url: str
    filename: str
    signature: str
    length: int


def version_number(value):
    if not re.fullmatch(VERSION, value):
        raise ValueError("Invalid update version.")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def public_key(info_path):
    key = plistlib.loads(Path(info_path).read_bytes())["SUPublicEDKey"]
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError("Invalid pinned public verification key.")
    return key


def verify_signature(path, signature, length, key, verifier):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or not 0 < length <= MAX_ARCHIVE_BYTES or path.stat().st_size != length:
        raise ValueError("Historical update size or file type does not match the signed feed.")
    result = subprocess.run([str(verifier), key, signature, str(length), str(path)], capture_output=True)
    if result.returncode:
        raise ValueError("Historical update signature is invalid; publishing was stopped.")


def signed_feed(path, key, verifier):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= MAX_FEED_BYTES:
        raise ValueError("Missing or oversized signed update feed.")
    data = path.read_bytes()
    if len(data) > MAX_FEED_BYTES:
        raise ValueError("Oversized signed update feed.")
    content, separator, tail = data.rpartition(PREFIX)
    block, closing, trailing = tail.partition(b"-->")
    if not separator or not closing or trailing.strip():
        raise ValueError("The update feed has no valid signing block.")
    fields = {}
    for line in block.splitlines():
        name, colon, value = line.partition(b":")
        if not colon or name not in (b"edSignature", b"length") or name in fields:
            raise ValueError("Malformed update feed signing block.")
        fields[name] = value.strip()
    if set(fields) != {b"edSignature", b"length"} or not fields[b"length"].isdigit() or int(fields[b"length"]) != len(content):
        raise ValueError("Signed update feed length does not match its contents.")
    signature = fields[b"edSignature"].decode("ascii")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid update feed signature.")
    # Authenticate bytes before handing any metadata to the XML parser.
    with tempfile.TemporaryDirectory(prefix="LocalWrite-feed-verification.") as directory:
        verified_bytes = Path(directory) / "content.xml"
        verified_bytes.write_bytes(content)
        verify_signature(verified_bytes, signature, len(content), key, verifier)
    if re.search(rb"<!\s*(?:DOCTYPE|ENTITY)\b", content, re.IGNORECASE):
        raise ValueError("Update feed document declarations are not supported.")
    return ET.fromstring(content)


def releases(root, build, generated=False):
    current = version_number(build)
    if root.tag != "rss" or len(root.findall("channel")) != 1:
        raise ValueError("Unexpected update feed structure.")
    result = {}
    numbers = set()
    for item in root.findall("./channel/item"):
        versions = item.findall(f"{{{SPARKLE}}}version")
        enclosures = item.findall("enclosure")
        if len(versions) != 1 or len(enclosures) != 1:
            raise ValueError("Each historical update must have exactly one version and archive.")
        version = versions[0].text or ""
        number = version_number(version)
        if number > current or number in numbers:
            raise ValueError("Duplicate or unexpected future update version.")
        numbers.add(number)
        enclosure = enclosures[0]
        filename = f"LocalWrite-{version}.zip"
        # Fixed origin, repo, tag and filename: no redirects to a user-supplied source.
        tag = build if generated else version
        url = f"https://github.com/{REPOSITORY}/releases/download/build-{tag}/{filename}"
        if enclosure.get("url") != url:
            raise ValueError("Historical archive URL does not match its signed release version.")
        signature = enclosure.get(f"{{{SPARKLE}}}edSignature", "")
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError("Missing or invalid historical archive signature.")
        length_text = enclosure.get("length", "")
        if not length_text.isascii() or not length_text.isdigit() or not 0 < int(length_text) <= MAX_ARCHIVE_BYTES:
            raise ValueError("Missing or invalid historical archive size.")
        result[version] = Release(version, url, filename, signature, int(length_text))
    if not result:
        raise ValueError("The signed update feed contains no authenticated releases.")
    return result


def verify_archive(path, release, key, verifier):
    # Never inspect/decompress a downloaded ZIP until its original signature passes.
    verify_signature(path, release.signature, release.length, key, verifier)
    with zipfile.ZipFile(path) as archive:
        name = "LocalWrite.app/Contents/Info.plist"
        entries = [entry for entry in archive.infolist() if entry.filename == name]
        if len(entries) != 1 or entries[0].file_size > MAX_FEED_BYTES:
            raise ValueError("Historical archive has no unique app configuration.")
        info = plistlib.loads(archive.read(entries[0]))
    if (info.get("CFBundleIdentifier") != "com.localwrite.mac"
            or info.get("CFBundleVersion") != release.version
            or info.get("SUPublicEDKey") != key):
        raise ValueError("Historical archive identity or version does not match its authenticated feed entry.")


def download_archive(release, directory):
    result = subprocess.run(["gh", "release", "download", f"build-{release.version}", "--repo", REPOSITORY,
                             "--pattern", release.filename, "--dir", str(directory)], capture_output=True)
    if result.returncode:
        raise ValueError("Could not download an authenticated historical update; publishing was stopped.")


def prepare(feed_path, info_path, build, archives_path, verifier):
    key = public_key(info_path)
    root = signed_feed(feed_path, key, verifier)
    history = releases(root, build)
    candidates = sorted((item for item in history.values() if version_number(item.version) < version_number(build)),
                        key=lambda item: version_number(item.version), reverse=True)[:3]
    archives = Path(archives_path)
    archives.mkdir(parents=True, exist_ok=True)
    if any(archives.iterdir()):
        raise ValueError("Historical verification requires an empty staging directory.")
    with tempfile.TemporaryDirectory(prefix="LocalWrite-history-verification.", dir=archives.parent) as directory:
        quarantine = Path(directory)
        for release in candidates:
            download_archive(release, quarantine)
            verify_archive(quarantine / release.filename, release, key, verifier)
        # Only verified archives can enter Sparkle's input directory.
        for release in candidates:
            shutil.copyfile(quarantine / release.filename, archives / release.filename)
        shutil.copyfile(feed_path, archives / "appcast.xml")
    print(f"Authenticated update feed and {len(candidates)} historical archives.")


def finalize(feed_path, history_path, info_path, build, archives_path, verifier):
    key = public_key(info_path)
    history = releases(signed_feed(history_path, key, verifier), build) if history_path else {}
    root = signed_feed(feed_path, key, verifier)
    generated = releases(root, build, generated=True)
    if build not in generated:
        raise ValueError("Generated feed is missing the new build.")
    for item in root.findall("./channel/item"):
        version = item.findtext(f"{{{SPARKLE}}}version")
        release = generated[version]
        if version == build:
            verify_archive(Path(archives_path) / release.filename, release, key, verifier)
        else:
            previous = history.get(version)
            if (previous is None or previous.length != release.length
                    or base64.b64decode(previous.signature) != base64.b64decode(release.signature)):
                raise ValueError("The generator attempted to authorize an unknown or changed historical archive.")
            item.find("enclosure").set("url", previous.url)
    # Re-sign this serialization only after history and archive invariants pass.
    ET.register_namespace("sparkle", SPARKLE)
    Path(feed_path).write_bytes(ET.tostring(root, encoding="utf-8", xml_declaration=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "finalize", "verify"))
    parser.add_argument("--feed", required=True)
    parser.add_argument("--info-plist", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--verifier", required=True)
    parser.add_argument("--archives")
    parser.add_argument("--history-feed")
    args = parser.parse_args()
    if args.command in ("prepare", "finalize") and not args.archives:
        parser.error("--archives is required for preparing/finalizing updates")
    if args.command == "prepare":
        prepare(args.feed, args.info_plist, args.build, args.archives, args.verifier)
    elif args.command == "finalize":
        finalize(args.feed, args.history_feed, args.info_plist, args.build, args.archives, args.verifier)
    else:
        releases(signed_feed(args.feed, public_key(args.info_plist), args.verifier), args.build)
        print("Published feed signature and release URLs verified with the pinned public key.")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never echo malformed remote payloads or a tool's diagnostic output.
        raise SystemExit("Update history authentication failed; nothing was published.")
