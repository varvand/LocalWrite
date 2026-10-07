from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AppReplacementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler_directory = tempfile.TemporaryDirectory(prefix="LocalWrite-replacement-tool.")
        cls.addClassCleanup(cls.compiler_directory.cleanup)
        cls.helper = Path(cls.compiler_directory.name) / "replace-app"
        subprocess.run([
            "swiftc", "-module-cache-path", str(ROOT / ".build/clang-cache"),
            str(ROOT / "scripts/replace-app.swift"), "-o", str(cls.helper),
        ], check=True, capture_output=True)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="LocalWrite-replacement-test.")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.staged = self.directory / "stage" / "LocalWrite.app"
        self.destination = self.directory / "Applications" / "LocalWrite.app"
        self.destination.parent.mkdir()
        (self.staged / "Contents" / "Resources").mkdir(parents=True)
        (self.staged / "Contents" / "Resources" / "current").write_text("new version")

    def previous_app(self):
        (self.destination / "Contents" / "Resources").mkdir(parents=True)
        (self.destination / "Contents" / "Resources" / "obsolete").write_text("old version")

    def replace(self):
        return subprocess.run([str(self.helper), str(self.staged), str(self.destination)],
                              capture_output=True, text=True)

    def test_replacing_an_app_removes_obsolete_resources(self):
        self.previous_app()
        result = self.replace()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "Contents" / "Resources" / "current").read_text(), "new version")
        self.assertFalse((self.destination / "Contents" / "Resources" / "obsolete").exists())
        self.assertFalse(self.staged.exists())

    def test_fresh_install_moves_the_complete_bundle(self):
        result = self.replace()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.destination / "Contents" / "Resources" / "current").exists())
        self.assertFalse(self.staged.exists())

    def test_missing_staged_app_keeps_the_previous_app(self):
        self.previous_app()
        self.staged.rename(self.staged.with_name("missing.app"))
        result = self.replace()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents" / "Resources" / "obsolete").read_text(), "old version")

    def test_replacement_uses_new_metadata_and_discards_old_quarantine(self):
        self.previous_app()
        subprocess.run(["xattr", "-w", "com.apple.quarantine", "0081;00000000;LocalWriteTest;", str(self.destination)], check=True)
        subprocess.run(["xattr", "-w", "com.localwrite.replacement-test", "new metadata", str(self.staged)], check=True)
        result = self.replace()
        self.assertEqual(result.returncode, 0, result.stderr)
        attributes = subprocess.check_output(["xattr", str(self.destination)], text=True).splitlines()
        self.assertNotIn("com.apple.quarantine", attributes)
        self.assertEqual(subprocess.check_output(["xattr", "-p", "com.localwrite.replacement-test", str(self.destination)], text=True).strip(), "new metadata")

    def test_destination_symlink_is_not_followed_or_replaced(self):
        target = self.directory / "Unrelated.app"
        target.mkdir()
        (target / "preserve").write_text("untouched")
        self.destination.symlink_to(target, target_is_directory=True)
        result = self.replace()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.destination.is_symlink())
        self.assertEqual((target / "preserve").read_text(), "untouched")
        self.assertTrue(self.staged.exists())

    def test_staged_app_inside_the_previous_bundle_is_rejected(self):
        self.previous_app()
        nested = self.destination / "Contents" / "LocalWrite.app"
        self.staged.rename(nested)
        result = subprocess.run([str(self.helper), str(nested), str(self.destination)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(nested.exists())
        self.assertEqual((self.destination / "Contents" / "Resources" / "obsolete").read_text(), "old version")

    def install_script(self, signature_is_valid):
        repository = self.directory / "repository"
        scripts = repository / "scripts"
        scripts.mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/install.sh", scripts / "install.sh")
        shutil.copy2(ROOT / "scripts/replace-app.swift", scripts / "replace-app.swift")
        shutil.copytree(self.staged, repository / "dist/LocalWrite.app")
        commands = self.directory / "commands"
        commands.mkdir()
        stubs = {
            "pgrep": "#!/bin/sh\nexit 1\n",
            "codesign": "#!/bin/sh\nexit " + ("0" if signature_is_valid else "1") + "\n",
            "open": "#!/bin/sh\nexit 0\n",
            "swift": "#!/usr/bin/env python3\nimport subprocess,sys\nsys.exit(subprocess.call([" + repr(str(self.helper)) + ", *sys.argv[-2:]]))\n",
        }
        for name, content in stubs.items():
            script = commands / name
            script.write_text(content)
            script.chmod(0o755)
        environment = dict(os.environ, LOCALWRITE_INSTALL_DIR=str(self.destination.parent),
                           PATH=str(commands) + os.pathsep + os.environ["PATH"])
        return subprocess.run(["bash", str(scripts / "install.sh")], env=environment,
                              capture_output=True, text=True)

    def test_installer_rejects_invalid_signature_before_touching_old_app(self):
        self.previous_app()
        result = self.install_script(signature_is_valid=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents" / "Resources" / "obsolete").read_text(), "old version")
        self.assertFalse((self.destination / "Contents" / "Resources" / "current").exists())
        self.assertFalse(list(self.destination.parent.glob(".LocalWrite-install.*")))

    def test_installer_replaces_the_entire_bundle(self):
        self.previous_app()
        result = self.install_script(signature_is_valid=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "Contents" / "Resources" / "current").read_text(), "new version")
        self.assertFalse((self.destination / "Contents" / "Resources" / "obsolete").exists())
        self.assertFalse(list(self.destination.parent.glob(".LocalWrite-install.*")))


if __name__ == "__main__":
    unittest.main()
