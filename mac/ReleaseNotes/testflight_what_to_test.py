#!/usr/bin/env python3
"""Sets a TestFlight build's What to Test (en-US) through the App Store Connect API. See README.md in this folder.

  set --text FILE --build N [--bundle-id co.stumpandroot.verbatim.ios] [--timeout 1200] [--interval 30]
      CI, after the TestFlight upload (.github/workflows/build-swift.yml): waits until App Store Connect has processed
      build N of the app (CFBundleVersion N), then creates or updates its en-US beta build localization with FILE's
      text (release_notes.py notes --format testflight). The key comes from the environment: ASC_KEY_ID,
      ASC_ISSUER_ID, and ASC_KEY_PATH (a .p8 file). Exits 1 with a reason on any problem; the workflow step turns that
      into a warning, so a slow or failing App Store Connect never fails the build.
  jwt-check --key FILE
      The test (tools/test-release-notes.sh): signs a token with FILE, a throwaway P-256 key, and verifies it with
      openssl, so the ES256 signing works without App Store Connect.

The key and the token are never printed or written anywhere but the key file the workflow makes. Needs python3 and
openssl (macOS has both), nothing else.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "co.stumpandroot.verbatim.ios"
LOCALE = "en-US"
# What to Test takes 4,000 characters.
LIMIT = 4000


class Problem(Exception):
    """A reason to stop, as a sentence for the workflow's warning."""


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def der_to_raw(der, size=32):
    """An ECDSA signature from openssl (DER: SEQUENCE of two INTEGERs) as JWT's ES256 wants it: r and s, 32 bytes
    each."""
    def read_len(b, i):
        n = b[i]
        if n < 0x80:
            return n, i + 1
        k = n & 0x7F
        return int.from_bytes(b[i + 1:i + 1 + k], "big"), i + 1 + k
    if not der or der[0] != 0x30:
        raise Problem("openssl's signature isn't DER")
    _, i = read_len(der, 1)
    out = b""
    for _ in range(2):
        if der[i] != 0x02:
            raise Problem("openssl's signature isn't two integers")
        n, i = read_len(der, i + 1)
        v = der[i:i + n].lstrip(b"\x00")
        i += n
        if len(v) > size:
            raise Problem("openssl's signature has an integer longer than %d bytes" % size)
        out += v.rjust(size, b"\x00")
    return out


def raw_to_der(raw):
    """The reverse of der_to_raw, for jwt-check."""
    def integer(v):
        v = v.lstrip(b"\x00") or b"\x00"
        if v[0] & 0x80:
            v = b"\x00" + v
        return b"\x02" + bytes([len(v)]) + v
    body = integer(raw[:32]) + integer(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


def sign(key_path, data):
    try:
        r = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path], input=data, capture_output=True, check=False)
    except OSError as e:
        raise Problem("couldn't run openssl (%s)" % e.strerror)
    if r.returncode != 0 or not r.stdout:
        # openssl's error names the problem (a bad key file) without the key itself.
        first = (r.stderr.decode("utf-8", "replace").strip().splitlines() or ["no reason given"])[0]
        raise Problem("openssl couldn't sign with the key: %s" % first[:200])
    return der_to_raw(r.stdout)


def token(key_id, issuer, key_path, now=None):
    """An App Store Connect API token (ES256), good for 15 minutes; Apple's limit is 20."""
    now = int(now if now is not None else time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
    signing_input = (b64url(json.dumps(header, separators=(",", ":")).encode()) + "." +
                     b64url(json.dumps(payload, separators=(",", ":")).encode())).encode("ascii")
    return signing_input.decode("ascii") + "." + b64url(sign(key_path, signing_input))


class Client:
    def __init__(self, key_id, issuer, key_path):
        self.key_id, self.issuer, self.key_path = key_id, issuer, key_path

    def call(self, method, path, query=None, body=None):
        url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + token(self.key_id, self.issuer, self.key_path))
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            raise Problem("%s %s: HTTP %d %s" % (method, path, e.code, errors(e.read())))
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise Problem("%s %s: %s" % (method, path, getattr(e, "reason", e)))


def errors(raw):
    """App Store Connect's error titles and details, without anything from the request."""
    try:
        found = json.loads(raw).get("errors", [])
        return "; ".join(("%s: %s" % (x.get("title", ""), x.get("detail", ""))).strip(": ") for x in found)[:500]
    except (ValueError, AttributeError):
        return ""


def find_app(api, bundle_id):
    apps = api.call("GET", "/v1/apps", {"filter[bundleId]": bundle_id, "fields[apps]": "bundleId", "limit": "5"}).get("data", [])
    app = next((a for a in apps if a.get("attributes", {}).get("bundleId") == bundle_id), None)
    if not app:
        raise Problem("App Store Connect has no app with the bundle ID %s for this key" % bundle_id)
    return app["id"]


def wait_for_build(api, app_id, build, timeout, interval, clock=time.monotonic, sleep=time.sleep):
    """The build's ID once App Store Connect has processed it (processingState VALID)."""
    deadline = clock() + timeout
    state = "not found yet"
    while True:
        found = api.call("GET", "/v1/builds", {"filter[app]": app_id, "filter[version]": str(build),
                                               "filter[preReleaseVersion.platform]": "IOS",
                                               "fields[builds]": "version,processingState", "limit": "5"}).get("data", [])
        b = next((x for x in found if x.get("attributes", {}).get("version") == str(build)), None)
        if b:
            state = b.get("attributes", {}).get("processingState") or "unknown"
            if state == "VALID":
                return b["id"]
            if state in ("FAILED", "INVALID"):
                raise Problem("build %s's processing ended %s" % (build, state))
        if clock() + interval > deadline:
            raise Problem("build %s wasn't processed within %d minutes (last seen: %s)" % (build, timeout // 60, state))
        print("Waiting for App Store Connect to process build %s (%s)" % (build, state), flush=True)
        sleep(interval)


def set_what_to_test(api, build_id, text):
    """Creates the build's en-US localization with the text, or updates the one there. Returns "created" or
    "updated"."""
    locs = api.call("GET", "/v1/builds/%s/betaBuildLocalizations" % build_id, {"fields[betaBuildLocalizations]": "locale,whatsNew", "limit": "50"}).get("data", [])
    loc = next((x for x in locs if x.get("attributes", {}).get("locale") == LOCALE), None)
    if loc:
        api.call("PATCH", "/v1/betaBuildLocalizations/%s" % loc["id"],
                 body={"data": {"type": "betaBuildLocalizations", "id": loc["id"], "attributes": {"whatsNew": text}}})
        return "updated"
    api.call("POST", "/v1/betaBuildLocalizations",
             body={"data": {"type": "betaBuildLocalizations", "attributes": {"locale": LOCALE, "whatsNew": text},
                            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    return "created"


def jwt_check(key_path):
    """Signs a token with a throwaway key and verifies the signature with openssl."""
    t = token("TESTKEY123", "00000000-0000-0000-0000-000000000000", key_path, now=1_800_000_000)
    head, payload, sig = t.split(".")
    pad = lambda s: s + "=" * (-len(s) % 4)
    h = json.loads(base64.urlsafe_b64decode(pad(head)))
    p = json.loads(base64.urlsafe_b64decode(pad(payload)))
    raw = base64.urlsafe_b64decode(pad(sig))
    assert h == {"alg": "ES256", "kid": "TESTKEY123", "typ": "JWT"}, h
    assert p["aud"] == "appstoreconnect-v1" and p["exp"] - p["iat"] <= 20 * 60, p
    assert len(raw) == 64, len(raw)
    assert der_to_raw(raw_to_der(raw)) == raw
    with tempfile.TemporaryDirectory() as d:
        pub, sig_file = os.path.join(d, "pub.pem"), os.path.join(d, "sig.der")
        subprocess.run(["openssl", "ec", "-in", key_path, "-pubout", "-out", pub], check=True, capture_output=True)
        with open(sig_file, "wb") as f:
            f.write(raw_to_der(raw))
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", sig_file],
                           input=(head + "." + payload).encode("ascii"), capture_output=True)
        assert r.returncode == 0, r.stdout + r.stderr
    print("jwt-check: ES256 token signed and verified")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("set", help="set a TestFlight build's What to Test")
    s.add_argument("--text", required=True, help="a file with the text (release_notes.py notes --format testflight)")
    s.add_argument("--build", required=True, type=int, help="the build number (CFBundleVersion)")
    s.add_argument("--bundle-id", default=BUNDLE_ID)
    s.add_argument("--timeout", type=int, default=1200, help="seconds to wait for processing (default: 20 minutes)")
    s.add_argument("--interval", type=int, default=30, help="seconds between checks (default: 30)")
    j = sub.add_parser("jwt-check", help="sign and verify a token with a throwaway key")
    j.add_argument("--key", required=True)
    a = p.parse_args(argv)

    if a.cmd == "jwt-check":
        return jwt_check(a.key)

    try:
        with open(a.text, encoding="utf-8") as f:
            text = f.read().strip()
        if not text:
            print("No release notes for build %d, so What to Test stays as it is." % a.build)
            return 0
        if len(text) > LIMIT:
            raise Problem("the text is %d characters; What to Test takes %d" % (len(text), LIMIT))
        key_id = os.environ.get("ASC_KEY_ID", "").strip()
        issuer = os.environ.get("ASC_ISSUER_ID", "").strip()
        key_path = os.environ.get("ASC_KEY_PATH", "")
        if not key_id or not issuer or not os.path.isfile(key_path):
            raise Problem("ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH must be set")
        api = Client(key_id, issuer, key_path)
        app_id = find_app(api, a.bundle_id)
        build_id = wait_for_build(api, app_id, a.build, a.timeout, a.interval)
        how = set_what_to_test(api, build_id, text)
        print("What to Test for build %d %s (%d characters)" % (a.build, how, len(text)))
        return 0
    except (Problem, OSError) as e:
        print("What to Test for build %d wasn't set: %s" % (a.build, e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
