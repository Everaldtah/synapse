"""Tiny App Store Connect API client (no dependencies beyond PyJWT + cryptography).

usage:  python tools/asc/asc.py METHOD PATH [json-body]
  e.g.  python tools/asc/asc.py GET "/v1/apps?filter%5BbundleId%5D=com.everaldtah.synapse"
        python tools/asc/asc.py GET "/v1/builds?filter%5Bapp%5D=6820327831&sort=-uploadedDate&limit=3"

The key comes from ASC_KEY_PATH (default ~/Downloads/AuthKey_<ASC_KEY_ID>.p8). In Git Bash on Windows set
MSYS_NO_PATHCONV=1 so "/v1/..." isn't rewritten into a file path.
"""
import json, os, sys, time, urllib.error, urllib.request

import jwt

KEY_ID = os.environ.get("ASC_KEY_ID", "454YN6H962")
ISSUER = os.environ.get("ASC_ISSUER_ID", "604b52fc-df53-4f1c-885e-d7a2ea469daa")
KEY_PATH = os.environ.get("ASC_KEY_PATH", os.path.expanduser(f"~/Downloads/AuthKey_{KEY_ID}.p8"))


def token() -> str:
    now = int(time.time())
    with open(KEY_PATH) as f:
        key = f.read()
    return jwt.encode({"iss": ISSUER, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"}, key,
                      algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})


def call(method: str, path: str, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"raw": raw.decode(errors="replace")}


if __name__ == "__main__":
    status, data = call(sys.argv[1], sys.argv[2], json.loads(sys.argv[3]) if len(sys.argv) > 3 else None)
    print(status)
    print(json.dumps(data, indent=1))
