from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.classify_release_run import classify


def jobs(**values: str) -> list[dict[str, str]]:
    return [{"name": name, "conclusion": value} for name, value in values.items()]


class ReleaseRunClassificationTests(unittest.TestCase):
    def test_classifies_native_release(self) -> None:
        self.assertEqual(classify(jobs(preflight="success", macos="success", windows="success", publish="success")), "native")

    def test_preserves_legacy_native_release_without_preflight_job(self) -> None:
        self.assertEqual(classify(jobs(macos="success", windows="success", publish="success")), "native")

    def test_classifies_only_exact_package_only_skip(self) -> None:
        self.assertEqual(classify(jobs(preflight="success", macos="skipped", windows="skipped", publish="skipped")), "package-only")

    def test_rejects_missing_or_failed_release_jobs(self) -> None:
        for value in (
            jobs(preflight="success", macos="skipped", windows="skipped", publish="success"),
            jobs(preflight="failure", macos="skipped", windows="skipped", publish="skipped"),
            jobs(macos="success", windows="failure", publish="skipped"),
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                classify(value)

    def test_rejects_ambiguous_duplicate_jobs(self) -> None:
        with self.assertRaises(ValueError):
            classify(jobs(preflight="success", macos="success", windows="success", publish="success") + [{"name": "publish", "conclusion": "skipped"}])


if __name__ == "__main__":
    unittest.main()
