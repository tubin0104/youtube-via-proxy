#!/usr/bin/env python
"""Export browser cookies (Chrome / Edge / Firefox) to a Netscape cookie jar.

Why a bespoke exporter instead of `yt-dlp --cookies-from-browser`:
  * it works while the browser is running (the DB is copied to a temp file first),
  * it gives a clear error when Chrome's app-bound encryption (v20) blocks reading,
  * it needs no third-party packages -DPAPI comes from ctypes, AES-GCM from Node
    when available, else from a pure-Python fallback.

On Windows, cookie values are encrypted with a key that lives in the browser's
"Local State" file, itself protected by DPAPI (per-user). We unwrap that with
ctypes/CryptUnprotectData, then decrypt each v10/v11/v20 value with AES-256-GCM.

Usage:
  python export-cookies.py --browser chrome --out cookies.txt
  python export-cookies.py --browser edge   --out cookies.txt --domain youtube.com
"""
import argparse
import base64
import ctypes
import ctypes.wintypes as wt
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile


# --------------------------------------------------------------------- DPAPI

class DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wt.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


def dpapi_unprotect(encrypted: bytes) -> bytes:
    crypt32 = ctypes.windll.crypt32
    kernel32 = ctypes.windll.kernel32
    buf = ctypes.create_string_buffer(encrypted, len(encrypted))
    blob_in = DATA_BLOB(len(encrypted), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
    blob_out = DATA_BLOB()
    ok = crypt32.CryptUnprotectData(
        ctypes.byref(blob_in), None, None, None, None, 0, ctypes.byref(blob_out)
    )
    if not ok:
        raise OSError("CryptUnprotectData failed")
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        kernel32.LocalFree(blob_out.pbData)


# ------------------------------------------------------------ browser profiles

def browser_paths(name: str):
    """Return (user_data_dir, cookie_db_candidates, local_state_path)."""
    local = os.environ.get("LOCALAPPDATA", "")
    roaming = os.environ.get("APPDATA", "")
    name = name.lower()

    if name == "chrome":
        udd = os.path.join(local, r"Google\Chrome\User Data")
    elif name == "edge":
        udd = os.path.join(local, r"Microsoft\Edge\User Data")
    elif name == "brave":
        udd = os.path.join(local, r"BraveSoftware\Brave-Browser\User Data")
    elif name in ("firefox", "ff"):
        udd = os.path.join(roaming, r"Mozilla\Firefox\Profiles")
    else:
        raise SystemExit(f"unsupported browser: {name}")

    if name == "firefox":
        return udd, [], None

    dbs = [
        os.path.join(udd, r"Default\Network\Cookies"),
        os.path.join(udd, r"Default\Cookies"),
        os.path.join(udd, r"Profile 1\Network\Cookies"),
        os.path.join(udd, r"Profile 2\Network\Cookies"),
    ]
    return udd, [d for d in dbs if os.path.exists(d)], os.path.join(udd, "Local State")


# ------------------------------------------------------------ crypto backends

def decrypt_values_native(master_key: bytes, blobs):
    """AES-256-GCM decryption via Node.js (present on most dev machines)."""
    node = shutil.which("node")
    if not node:
        return None
    payload = json.dumps(
        {
            "key": base64.b64encode(master_key).decode(),
            "blobs": [base64.b64encode(b).decode() for b in blobs],
        }
    )
    js = r"""
const crypto = require('crypto');
let raw = '';
process.stdin.on('data', d => raw += d);
process.stdin.on('end', () => {
  const {key, blobs} = JSON.parse(raw);
  const k = Buffer.from(key, 'base64');
  const out = blobs.map(b64 => {
    const blob = Buffer.from(b64, 'base64');
    const scheme = blob.subarray(0, 3).toString('latin1');
    if (scheme !== 'v10' && scheme !== 'v11' && scheme !== 'v20') return null;
    try {
      const d = crypto.createDecipheriv('aes-256-gcm', k, blob.subarray(3, 15));
      d.setAuthTag(blob.subarray(blob.length - 16));
      let plain = Buffer.concat([d.update(blob.subarray(15, blob.length - 16)), d.final()]);
      // Chrome >=127 prepends a 32-byte binary header to the plaintext.
      if (plain.length > 32) {
        const head = plain.subarray(0, 32);
        let printable = true;
        for (const byte of head) if (byte < 0x20 || byte > 0x7e) { printable = false; break; }
        if (!printable) plain = plain.subarray(32);
      }
      return plain.toString('utf8');    } catch (e) { return null; }
  });
  process.stdout.write(JSON.stringify(out));
});
"""
    try:
        proc = subprocess.run(
            [node, "-e", js], input=payload.encode(), capture_output=True, timeout=60
        )
        if proc.returncode != 0:
            return None
        return json.loads(proc.stdout.decode())
    except Exception:
        return None


def decrypt_values_pure(master_key: bytes, blobs):
    """Pure-Python AES-GCM fallback (only if `cryptography` is installed)."""
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError:
        return None
    out = []
    for blob in blobs:
        scheme = blob[:3]
        if scheme not in (b"v10", b"v11", b"v20"):
            out.append(None)
            continue
        try:
            plain = AESGCM(master_key).decrypt(blob[3:15], blob[15:-16] + blob[-16:], None)
            plain = strip_app_bound_header(plain)
            out.append(plain.decode("utf-8", "replace"))
        except Exception:
            out.append(None)
    return out


def strip_app_bound_header(plain: bytes) -> bytes:
    """Chrome >=127 (scheme "v20") prepends a 32-byte binary header to the
    plaintext. It is not valid cookie text, so drop it when the first bytes are
    clearly not printable ASCII."""
    if len(plain) > 32 and any(b < 0x20 or b > 0x7e for b in plain[:32]):
        return plain[32:]
    return plain


def chrome_time_to_unix(expires: int) -> int:
    """Convert Chrome's expires_utc to a Unix timestamp.

    Chrome stores microseconds since 1601-01-01; older builds stored seconds.
    """
    if not expires:
        return 0
    if expires > 1e13:
        return int(expires / 1e6 - 11644473600)
    return int(expires - 11644473600)


def build_netscape_lines(records, header=True):
    """Render cookie records as Netscape cookie-jar lines.

    Each record needs: host, path, secure, httponly, expires, name, plain.
    Records whose value is empty are skipped.
    """
    lines = ["# Netscape HTTP Cookie File", "# exported by export-cookies.py", ""] if header else []
    ok = 0
    for r in records:
        value = r.get("plain") or ""
        if not value:
            continue
        host = r["host"]
        prefix = "#HttpOnly_" if r.get("httponly") else ""
        lines.append(
            "\t".join([
                prefix + host,
                "TRUE" if host.startswith(".") else "FALSE",
                r.get("path") or "/",
                "TRUE" if r.get("secure") else "FALSE",
                str(chrome_time_to_unix(r.get("expires") or 0)),
                r["name"],
                value,
            ])
        )
        ok += 1
    return lines, ok


# --------------------------------------------------------------- firefox path

def export_firefox(udd, out_path, domain):
    profiles = []
    if os.path.isdir(udd):
        for name in os.listdir(udd):
            d = os.path.join(udd, name)
            if os.path.isdir(d) and os.path.exists(os.path.join(d, "cookies.sqlite")):
                profiles.append(d)
    if not profiles:
        raise SystemExit("no Firefox profile with cookies.sqlite found")

    rows = []
    for p in profiles:
        src = os.path.join(p, "cookies.sqlite")
        tmp = os.path.join(tempfile.gettempdir(), f"ffcookies_{os.getpid()}.db")
        shutil.copyfile(src, tmp)
        con = sqlite3.connect(tmp)
        cur = con.cursor()
        cur.execute(
            "SELECT host, path, isSecure, expiry, name, value FROM moz_cookies "
            "WHERE host LIKE ?",
            ("%" + domain + "%",),
        )
        rows.extend(cur.fetchall())
        con.close()
        try:
            os.remove(tmp)
        except OSError:
            pass

    lines = ["# Netscape HTTP Cookie File", "# exported by export-cookies.py", ""]
    for host, path, secure, expiry, name, value in rows:
        lines.append(
            "\t".join(
                [host, "TRUE" if host.startswith(".") else "FALSE", path,
                 "TRUE" if secure else "FALSE", str(expiry or 0), name, value]
            )
        )
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {len(rows)} cookies -> {out_path}")


# ----------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="chrome", help="chrome | edge | brave | firefox")
    ap.add_argument("--out", default="cookies.txt")
    ap.add_argument("--domain", default="youtube.com")
    args = ap.parse_args()

    udd, dbs, local_state = browser_paths(args.browser)

    if args.browser.lower() in ("firefox", "ff"):
        export_firefox(udd, args.out, args.domain)
        return 0

    if not dbs:
        raise SystemExit(f"no cookie database found under {udd}")
    if not local_state or not os.path.exists(local_state):
        raise SystemExit(f"Local State not found: {local_state}")

    try:
        with open(local_state, "r", encoding="utf-8") as f:
            state = json.load(f)
        enc_key = base64.b64decode(state["os_crypt"]["encrypted_key"])
    except (OSError, ValueError, KeyError, TypeError) as e:
        raise SystemExit(f"cannot read the encryption key from Local State: {e}")

    if enc_key[:5] != b"DPAPI":
        raise SystemExit(f"unexpected key prefix {enc_key[:5]!r}")

    try:
        master_key = dpapi_unprotect(enc_key[5:])
    except OSError as e:
        raise SystemExit(
            f"DPAPI could not unwrap the cookie key ({e}). This normally means the "
            "profile was created by a different Windows user account."
        )
    print(f"master key: {len(master_key)} bytes")

    # Read every profile's DB, collecting encrypted blobs.
    records = []
    for db_src in dbs:
        # Copy: the browser holds the DB open and SQLite would otherwise fail.
        tmp = os.path.join(tempfile.gettempdir(), f"ck_{os.getpid()}_{abs(hash(db_src))}.db")
        shutil.copyfile(db_src, tmp)
        con = sqlite3.connect(tmp)
        cur = con.cursor()
        cur.execute(
            "SELECT host_key, path, is_secure, is_httponly, expires_utc, name, value, "
            "encrypted_value FROM cookies WHERE host_key LIKE ?",
            ("%" + args.domain + "%",),
        )
        for row in cur.fetchall():
            host, path, secure, ho, exp, name, plain, enc = row
            records.append(
                {"host": host, "path": path, "secure": secure, "httponly": ho,
                 "expires": exp or 0, "name": name, "plain": plain or "",
                 "enc": bytes(enc) if enc else b""}
            )
        con.close()
        try:
            os.remove(tmp)
        except OSError:
            pass

    # Decrypt what needs decrypting.
    need = [r["enc"] for r in records if not r["plain"] and r["enc"]]
    if need:
        values = decrypt_values_native(master_key, need)
        backend = "node"
        if values is None:
            values = decrypt_values_pure(master_key, need)
            backend = "cryptography"
        if values is None:
            raise SystemExit(
                "cannot decrypt: install Node.js (fastest) or pip install cryptography"
            )
        print(f"decrypt backend: {backend}")
        it = iter(values)
        for r in records:
            if not r["plain"] and r["enc"]:
                r["plain"] = next(it) or ""

    lines, ok = build_netscape_lines(records)
    v20_fail = sum(
        1 for r in records
        if not (r.get("plain") or "") and r.get("enc", b"")[:3] == b"v20"
    )

    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    print(f"wrote {ok} cookies -> {args.out}")
    if v20_fail:
        print(
            f"WARNING: {v20_fail} cookies use Chrome app-bound encryption (v20) and "
            "could not be decrypted. Try Edge or Firefox if YouTube still refuses.",
            file=sys.stderr,
        )
    if ok == 0:
        raise SystemExit(1)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:  # noqa: BLE001 - top-level guard, must stay readable
        # A raw traceback is useless to someone who just wants cookies exported.
        print(f"export failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
