import base64
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("update_history", ROOT / "scripts/update-history.py")
HISTORY = importlib.util.module_from_spec(SPEC)
# dataclass annotations need the module to be registered during dynamic import.
import sys
sys.modules[SPEC.name] = HISTORY
SPEC.loader.exec_module(HISTORY)


class UpdateHistoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory(prefix="LocalWrite-verifier-tests.")
        cls.addClassCleanup(cls.tools.cleanup)
        directory = Path(cls.tools.name)
        cls.verifier = directory / "verify"
        subprocess.run(["swiftc", str(ROOT / "scripts/verify-update-signature.swift"), "-o", str(cls.verifier)], check=True)
        # A fixed synthetic fixture key, unrelated to either production identity.
        source = directory / "sign.swift"
        source.write_text('''import CryptoKit
import Foundation
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((0..<32).map { UInt8($0) }))
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
print(key.publicKey.rawRepresentation.base64EncodedString())
print(try key.signature(for: data).base64EncodedString())
''')
        cls.signer = directory / "sign"
        subprocess.run(["swiftc", str(source), "-o", str(cls.signer)], check=True)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="LocalWrite-history-test.")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.key, _ = self.sign(b"test fixture")
        self.info = self.directory / "Info.plist"
        self.info.write_bytes(plistlib.dumps({"SUPublicEDKey": self.key}))

    def sign(self, data):
        path = self.directory / "sign-input"
        path.write_bytes(data)
        output = subprocess.check_output([str(self.signer), str(path)], text=True).splitlines()
        return output[0], output[1]

    def archive(self, version="2.3.0", bundle_version=None):
        path = self.directory / f"LocalWrite-{version}.zip"
        info = {"CFBundleIdentifier": "com.localwrite.mac", "CFBundleVersion": bundle_version or version,
                "SUPublicEDKey": self.key}
        with zipfile.ZipFile(path, "w") as bundle:
            bundle.writestr("LocalWrite.app/Contents/Info.plist", plistlib.dumps(info))
            bundle.writestr("LocalWrite.app/Contents/Resources/marker", "original")
        _, signature = self.sign(path.read_bytes())
        url = f"https://github.com/varvand/LocalWrite/releases/download/build-{version}/{path.name}"
        return path, HISTORY.Release(version, url, path.name, signature, path.stat().st_size)

    def feed(self, releases, name="appcast.xml", generated_build=None):
        ET.register_namespace("sparkle", HISTORY.SPARKLE)
        root = ET.Element("rss", version="2.0")
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Signed test feed"
        for release in releases:
            item = ET.SubElement(channel, "item")
            ET.SubElement(item, f"{{{HISTORY.SPARKLE}}}version").text = release.version
            url = release.url if not generated_build else f"https://github.com/varvand/LocalWrite/releases/download/build-{generated_build}/{release.filename}"
            ET.SubElement(item, "enclosure", {"url": url, "length": str(release.length),
                          f"{{{HISTORY.SPARKLE}}}edSignature": release.signature})
        content = ET.tostring(root, encoding="utf-8", xml_declaration=True)
        _, signature = self.sign(content)
        path = self.directory / name
        path.write_bytes(content + HISTORY.PREFIX + f"edSignature: {signature}\nlength: {len(content)}\n-->".encode())
        return path

    def prepare(self, feed, archives=None):
        archives = archives or self.directory / "staging"
        HISTORY.prepare(feed, self.info, "2.4.0", archives, self.verifier)
        return archives

    def test_valid_feed_downloads_only_its_exact_authenticated_archive(self):
        archive, release = self.archive()
        feed = self.feed([release])
        downloads = []
        def download(item, directory):
            downloads.append(item)
            shutil.copyfile(archive, directory / item.filename)
            (directory / "unlisted.zip").write_bytes(b"untrusted extra file")
        with patch.object(HISTORY, "download_archive", side_effect=download):
            staging = self.prepare(feed)
        self.assertEqual(downloads, [release])
        self.assertEqual(sorted(item.name for item in staging.iterdir()), [release.filename, "appcast.xml"])

    def test_unsigned_or_tampered_feed_is_rejected_before_download_or_xml_parsing(self):
        _, release = self.archive()
        feed = self.feed([release])
        original = feed.read_bytes()
        bad_feeds = [original.split(HISTORY.PREFIX)[0], original.replace(b"Signed test", b"Altered test"),
                     original + b"<rss/>", original.replace(b"length:", b"unknown:")]
        for content in bad_feeds:
            with self.subTest(content=content[-30:]):
                feed.write_bytes(content)
                with patch.object(HISTORY, "download_archive") as download, patch.object(HISTORY.ET, "fromstring") as parse:
                    with self.assertRaises(ValueError):
                        self.prepare(feed)
                download.assert_not_called()
                parse.assert_not_called()

    def test_feed_signed_by_a_different_key_is_rejected(self):
        _, release = self.archive()
        feed = self.feed([release])
        self.info.write_bytes(plistlib.dumps({"SUPublicEDKey": base64.b64encode(bytes(32)).decode()}))
        with self.assertRaises(ValueError):
            self.prepare(feed)

    def test_altered_archive_is_rejected_before_zip_inspection_and_staging(self):
        archive, release = self.archive()
        feed = self.feed([release])
        # Keep the byte count unchanged so this exercises cryptography, not size checks.
        tampered = archive.read_bytes().replace(b"original", b"tampered")
        self.assertEqual(len(tampered), release.length)
        def download(item, directory):
            (directory / item.filename).write_bytes(tampered)
        with patch.object(HISTORY, "download_archive", side_effect=download), patch.object(HISTORY.zipfile, "ZipFile") as inspect:
            with self.assertRaises(ValueError):
                self.prepare(feed)
        inspect.assert_not_called()
        self.assertEqual(list((self.directory / "staging").iterdir()), [])

    def test_missing_or_truncated_archive_stops_publication(self):
        archive, release = self.archive()
        feed = self.feed([release])
        for data in [None, archive.read_bytes()[:-1]]:
            with self.subTest(missing=data is None):
                def download(item, directory):
                    if data is not None:
                        (directory / item.filename).write_bytes(data)
                with patch.object(HISTORY, "download_archive", side_effect=download), self.assertRaises(ValueError):
                    self.prepare(feed)

    def test_valid_signature_with_wrong_bundle_version_is_rejected(self):
        archive, release = self.archive(bundle_version="9.9.0")
        feed = self.feed([release])
        with patch.object(HISTORY, "download_archive", side_effect=lambda item, directory: shutil.copyfile(archive, directory / item.filename)):
            with self.assertRaises(ValueError):
                self.prepare(feed)

    def test_authenticated_metadata_cannot_redirect_or_add_unknown_versions(self):
        _, release = self.archive()
        invalid = [dict(url="https://evil.invalid/LocalWrite-2.3.0.zip"),
                   dict(url=release.url + "?token=anything"),
                   dict(url=release.url.replace("build-2.3.0", "build-2.2.0")),
                   dict(version="9.9.0"), dict(signature=""), dict(length=0)]
        for overrides in invalid:
            with self.subTest(overrides=overrides):
                item = HISTORY.Release(**(release.__dict__ | overrides))
                feed = self.feed([item])
                with patch.object(HISTORY, "download_archive") as download, self.assertRaises(ValueError):
                    self.prepare(feed)
                download.assert_not_called()
        with self.assertRaises(ValueError):
            self.prepare(self.feed([release, release]))

    def test_unverified_existing_staging_files_are_not_reused(self):
        _, release = self.archive()
        staging = self.directory / "staging"
        staging.mkdir()
        (staging / "unverified.zip").write_bytes(b"unverified")
        with self.assertRaises(ValueError):
            self.prepare(self.feed([release]), staging)

    def test_finalization_preserves_original_links_and_archive_signatures(self):
        _, old = self.archive()
        _, current = self.archive("2.4.0")
        history = self.feed([old], "history.xml")
        generated = self.feed([current, old], generated_build="2.4.0")
        HISTORY.finalize(generated, history, self.info, "2.4.0", self.directory, self.verifier)
        self.assertNotIn(HISTORY.PREFIX, generated.read_bytes())
        result = HISTORY.releases(ET.parse(generated).getroot(), "2.4.0")
        self.assertEqual(result[old.version], old)
        self.assertEqual(result[current.version], current)

    def test_generator_cannot_authorize_a_changed_or_unknown_historical_archive(self):
        _, old = self.archive()
        _, current = self.archive("2.4.0")
        history = self.feed([old], "history.xml")
        _, changed_signature = self.sign(b"altered historical bytes")
        changed = HISTORY.Release(**(old.__dict__ | {"signature": changed_signature}))
        _, unknown = self.archive("2.2.0")
        for item in [changed, unknown]:
            with self.subTest(version=item.version):
                generated = self.feed([current, item], generated_build="2.4.0")
                original = generated.read_bytes()
                with self.assertRaises(ValueError):
                    HISTORY.finalize(generated, history, self.info, "2.4.0", self.directory, self.verifier)
                self.assertEqual(generated.read_bytes(), original)

    def test_generated_new_archive_must_also_match_its_signed_entry(self):
        archive, current = self.archive("2.4.0")
        generated = self.feed([current], generated_build="2.4.0")
        archive.write_bytes(archive.read_bytes().replace(b"original", b"tampered"))
        with self.assertRaises(ValueError):
            HISTORY.finalize(generated, None, self.info, "2.4.0", self.directory, self.verifier)


if __name__ == "__main__":
    unittest.main()
