import base64
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("verify_update", ROOT / "scripts/verify-update-archive.py")
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class UpdateArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="LocalWrite-release-test.")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def archive(self, extra_name=None, extra_data=b"", overrides=None):
        info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        info.update(overrides or {})
        archive = self.directory / "app.zip"
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("LocalWrite.app/Contents/Info.plist", plistlib.dumps(info))
            if extra_name:
                bundle.writestr(extra_name, extra_data)
        return archive

    def test_public_verification_key_is_allowed(self):
        VERIFIER.verify(self.archive())

    def test_accidentally_bundled_credentials_are_rejected(self):
        for name in ["certificate.p12", "identity.KEYCHAIN-DB", ".env"]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                VERIFIER.verify(self.archive("LocalWrite.app/Contents/Resources/" + name, b"fixture"))

    def test_private_key_and_token_contents_are_rejected(self):
        payloads = [b"-----BEGIN PRIVATE KEY-----\nfixture", b"ghp_" + b"a" * 36]
        for payload in payloads:
            with self.subTest(), self.assertRaises(ValueError):
                VERIFIER.verify(self.archive("LocalWrite.app/Contents/Resources/config.txt", payload))

    def test_exact_signing_seed_leak_is_rejected(self):
        # Synthetic test bytes, unrelated to the real signing key.
        seed = bytes(range(32))
        key = self.directory / "test-key"
        key.write_bytes(base64.b64encode(seed))
        for leaked in [seed, base64.b64encode(seed)]:
            with self.subTest(), self.assertRaises(ValueError):
                VERIFIER.verify(self.archive("LocalWrite.app/Contents/Resources/config", leaked), key)

    def test_weakened_update_verification_is_rejected(self):
        for flag in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"]:
            with self.subTest(flag=flag), self.assertRaises(ValueError):
                VERIFIER.verify(self.archive(overrides={flag: False}))

    def test_archive_path_traversal_is_rejected(self):
        with self.assertRaises(ValueError):
            VERIFIER.verify(self.archive("LocalWrite.app/../../outside", b"fixture"))
