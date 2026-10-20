import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / "scripts/signing_identity.py"
spec = importlib.util.spec_from_file_location("signing_identity", path)
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningTests(unittest.TestCase):
    def test_single_existing_certificate(self):
        fingerprint = "A" * 40
        text = f'  1) {fingerprint} "Developer ID Application: Example (TEAM)"\n1 valid identities found'
        self.assertEqual(signing.select_identity(text), fingerprint)

    def test_explicit_identity_is_respected(self):
        self.assertEqual(signing.select_identity("", "selected-public-identity"), "selected-public-identity")

    def test_temporary_signature_requires_explicit_choice(self):
        self.assertEqual(signing.select_identity("", "-"), "-")
        with self.assertRaises(ValueError):
            signing.select_identity("0 valid identities found")

    def test_multiple_identities_do_not_choose_arbitrarily(self):
        text = f'1) {"A"*40} "Apple Development: One"\n2) {"B"*40} "Developer ID Application: Two"'
        with self.assertRaises(ValueError):
            signing.select_identity(text)

    def test_non_application_certificate_is_not_selected(self):
        with self.assertRaises(ValueError):
            signing.select_identity(f'1) {"A"*40} "Developer ID Installer: Example"')


if __name__ == "__main__":
    unittest.main()
