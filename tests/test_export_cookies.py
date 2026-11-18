#!/usr/bin/env python
"""Unit tests for scripts/export-cookies.py.

These run with only the Python standard library — no browser, no network, no
Windows. Anything DPAPI- or Node-dependent is exercised through its pure
counterpart, so CI on Linux/macOS works as well.

Run:
    python -m unittest discover -s tests -v
"""
import base64
import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "scripts", "export-cookies.py")


def load_module():
    """Load export-cookies.py despite the hyphen in its filename."""
    spec = importlib.util.spec_from_file_location("export_cookies", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ec = load_module()


class TestStripAppBoundHeader(unittest.TestCase):
    """Chrome >=127 prepends 32 binary bytes (v20 scheme)."""

    def test_strips_binary_header(self):
        header = bytes(range(0, 32))          # all non-printable
        self.assertEqual(ec.strip_app_bound_header(header + b"SESSION_VALUE"), b"SESSION_VALUE")

    def test_keeps_plain_printable_value(self):
        value = b"SID=abc123; this is a normal cookie value"
        self.assertEqual(ec.strip_app_bound_header(value), value)

    def test_short_values_untouched(self):
        # <= 32 bytes can never carry the header
        self.assertEqual(ec.strip_app_bound_header(b"short"), b"short")

    def test_header_of_length_32_without_payload(self):
        # exactly 32 bytes: nothing to strip, must not crash or truncate to b""
        data = bytes(range(0, 32))
        self.assertEqual(ec.strip_app_bound_header(data), data)


class TestChromeTimeToUnix(unittest.TestCase):
    def test_zero(self):
        self.assertEqual(ec.chrome_time_to_unix(0), 0)

    def test_microseconds_format(self):
        # 2024-01-01T00:00:00Z in Chrome epoch microseconds
        chrome_us = (1704067200 + 11644473600) * 1_000_000
        self.assertEqual(ec.chrome_time_to_unix(chrome_us), 1704067200)

    def test_seconds_format(self):
        chrome_s = 1704067200 + 11644473600
        self.assertEqual(ec.chrome_time_to_unix(chrome_s), 1704067200)


class TestBuildNetscapeLines(unittest.TestCase):
    def rec(self, **over):
        base = {
            "host": ".youtube.com", "path": "/", "secure": True, "httponly": False,
            "expires": 0, "name": "SID", "plain": "value123",
        }
        base.update(over)
        return base

    def test_header_present(self):
        lines, ok = ec.build_netscape_lines([self.rec()])
        self.assertEqual(lines[0], "# Netscape HTTP Cookie File")
        self.assertEqual(ok, 1)

    def test_header_can_be_suppressed(self):
        lines, _ = ec.build_netscape_lines([self.rec()], header=False)
        self.assertFalse(lines[0].startswith("# Netscape"))

    def test_domain_dot_sets_subdomain_flag(self):
        lines, _ = ec.build_netscape_lines([self.rec(host=".youtube.com")])
        self.assertIn("\tTRUE\t", lines[-1])

    def test_domain_without_dot_clears_subdomain_flag(self):
        lines, _ = ec.build_netscape_lines([self.rec(host="www.youtube.com")])
        fields = lines[-1].split("\t")
        self.assertEqual(fields[1], "FALSE")

    def test_httponly_prefix_is_not_a_comment(self):
        """#HttpOnly_ lines are real cookies — consumers must not drop them."""
        lines, ok = ec.build_netscape_lines([self.rec(httponly=True)])
        self.assertTrue(lines[-1].startswith("#HttpOnly_.youtube.com"))
        self.assertEqual(ok, 1)

    def test_secure_flag_rendered(self):
        lines, _ = ec.build_netscape_lines([self.rec(secure=True)])
        self.assertEqual(lines[-1].split("\t")[3], "TRUE")

    def test_empty_values_skipped(self):
        lines, ok = ec.build_netscape_lines([
            self.rec(name="EMPTY", plain=""),
            self.rec(name="FULL", plain="x"),
        ])
        self.assertEqual(ok, 1)
        self.assertNotIn("EMPTY", "\n".join(lines))

    def test_missing_plain_key_skipped(self):
        r = self.rec()
        del r["plain"]
        _, ok = ec.build_netscape_lines([r])
        self.assertEqual(ok, 0)

    def test_seven_fields_per_line(self):
        lines, _ = ec.build_netscape_lines([self.rec(httponly=True)])
        self.assertEqual(len(lines[-1].split("\t")), 7)

    def test_path_defaults_to_slash(self):
        lines, _ = ec.build_netscape_lines([self.rec(path="")])
        self.assertEqual(lines[-1].split("\t")[2], "/")


class TestBrowserPaths(unittest.TestCase):
    def test_unknown_browser_raises(self):
        with self.assertRaises(SystemExit):
            ec.browser_paths("netscape")

    def test_firefox_returns_no_cookie_dbs(self):
        # Firefox keeps cookies in a per-profile sqlite file, not the Chrome layout
        udd, dbs, local_state = ec.browser_paths("firefox")
        self.assertEqual(dbs, [])
        self.assertIsNone(local_state)

    def test_known_browsers_have_paths(self):
        for name in ("chrome", "edge", "brave"):
            udd, dbs, local_state = ec.browser_paths(name)
            self.assertTrue(udd)
            self.assertIsInstance(dbs, list)
            self.assertTrue(local_state.endswith("Local State"))


class TestNodeDecryptRoundTrip(unittest.TestCase):
    """Verify the Node AES-256-GCM backend against a value we encrypt here.

    Skipped when node is unavailable, so this stays optional in CI.
    """

    def setUp(self):
        import shutil
        self.node = shutil.which("node")

    @unittest.skipUnless(os.name == "nt" or True, "node backend is cross-platform")
    def test_roundtrip(self):
        if not self.node:
            self.skipTest("node not installed")
        import json
        import subprocess

        key = bytes(range(32))
        plaintext = b"SID=roundtrip-test-value"
        # Build a v10 blob with the same layout Chrome uses.
        script = """
const crypto = require('crypto');
const key = Buffer.from(process.argv[1], 'hex');
const plain = Buffer.from(process.argv[2], 'utf8');
const nonce = Buffer.alloc(12, 7);
const c = crypto.createCipheriv('aes-256-gcm', key, nonce);
const ct = Buffer.concat([c.update(plain), c.final()]);
const tag = c.getAuthTag();
process.stdout.write(Buffer.concat([Buffer.from('v10'), nonce, ct, tag]).toString('base64'));
"""
        proc = subprocess.run(
            [self.node, "-e", script, key.hex(), plaintext.decode()],
            capture_output=True, timeout=60,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        blob = base64.b64decode(proc.stdout.decode().strip())

        values = ec.decrypt_values_native(key, [blob])
        if values is None:
            self.skipTest("node backend unavailable")
        self.assertEqual(values[0], plaintext.decode())

    def test_bad_blob_returns_none_entry(self):
        if not self.node:
            self.skipTest("node not installed")
        # Not a valid v1x blob -> the backend reports None for that entry
        values = ec.decrypt_values_native(bytes(32), [b"garbage-not-a-cookie"])
        if values is None:
            self.skipTest("node backend unavailable")
        self.assertIsNone(values[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
