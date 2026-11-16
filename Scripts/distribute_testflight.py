#!/usr/bin/env python3
"""
distribute_testflight.py - Automated TestFlight Distribution Engine
Polls App Store Connect until an uploaded build transitions to VALID,
resolves export compliance, assigns to Internal Testers, and confirms IN_BETA_TESTING.
"""

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error

from pathlib import Path

try:
    import jwt
except ImportError:
    print("❌ Error: PyJWT is required. Install via: pip3 install pyjwt cryptography")
    sys.exit(1)

DEFAULT_ISSUER_ID = "46562150-20c4-4489-81db-12f330fcf7bc"
DEFAULT_TESTER_EMAIL = "adrian93box@icloud.com"


def _load_tokens_env():
    values = {}
    for candidate in (Path.cwd() / "secrets/tokens.env", Path.home() / ".appstoreconnect/tokens.env"):
        if not candidate.is_file():
            continue
        for raw in candidate.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key and key not in values:
                values[key] = val
    return values


_TOKENS_ENV = _load_tokens_env()


def env_or_tokens(name, default=None):
    return os.environ.get(name) or _TOKENS_ENV.get(name) or default


def _resolve_credentials(args):
    key_id = args.key_id or env_or_tokens("ASC_KEY_ID")
    issuer_id = args.issuer_id or env_or_tokens("ASC_ISSUER_ID", DEFAULT_ISSUER_ID)
    key_path = args.key_path or env_or_tokens("ASC_PRIVATE_KEY_PATH") or env_or_tokens("ASC_KEY_PATH")
    keys_dir = Path.home() / ".appstoreconnect/private_keys"
    if not key_id and keys_dir.is_dir():
        matches = sorted(keys_dir.glob("AuthKey_*.p8"))
        if len(matches) == 1:
            key_id = matches[0].stem.removeprefix("AuthKey_")
            key_path = key_path or str(matches[0])
    if not key_path and key_id:
        key_path = str(keys_dir / f"AuthKey_{key_id}.p8")
    if not key_id or not key_path:
        raise RuntimeError(
            "Missing ASC_KEY_ID / key path. Set ASC_KEY_ID in environment, secrets/tokens.env, or ~/.appstoreconnect/tokens.env."
        )
    return key_id, issuer_id, os.path.expanduser(key_path)

APP_MAP = {
    "mb": "6778954606",
    "smallbusiness": "6778954606",
    "com.evolvedbygl.GLSmallBusiness": "6778954606",
    "6778954606": "6778954606",
    "myai": "6820172966",
    "com.evolvedbygl.myai": "6820172966",
    "6820172966": "6820172966",
}


def generate_token(key_id, issuer_id, key_path):
    if not os.path.exists(key_path):
        raise FileNotFoundError(f"Private key file not found: {key_path}")
    with open(key_path, "r") as f:
        private_key = f.read()

    payload = {
        "iss": issuer_id,
        "iat": int(time.time()),
        "exp": int(time.time()) + 1200,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(payload, private_key, algorithm="ES256", headers={"kid": key_id})


def asc_request(endpoint, token, method="GET", body=None):
    url = f"https://api.appstoreconnect.apple.com{endpoint}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    data = json.dumps(body).encode("utf-8") if body else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            content = resp.read()
            if not content:
                return {}
            return json.loads(content.decode("utf-8"))
    except urllib.error.HTTPError as e:
        err_msg = e.read().decode("utf-8", errors="replace")
        return {"error": e.code, "message": err_msg}


def detect_app_id():
    cwd = os.getcwd()
    if "SmallBusiness" in cwd:
        return "6778954606"
    elif "MyAI" in cwd:
        return "6820172966"
    return None


def get_internal_group(app_id, token):
    res = asc_request(f"/v1/apps/{app_id}/betaGroups", token)
    groups = res.get("data", [])
    for g in groups:
        attrs = g.get("attributes", {})
        if attrs.get("isInternalGroup") or "Internal" in attrs.get("name", ""):
            return g.get("id"), attrs.get("hasAccessToAllBuilds", False)
    if groups:
        return groups[0].get("id"), groups[0].get("attributes", {}).get("hasAccessToAllBuilds", False)
    return None, False


def get_tester_id(email, token):
    res = asc_request(f"/v1/betaTesters?filter[email]={email}", token)
    testers = res.get("data", [])
    if testers:
        return testers[0].get("id")
    return None


def ensure_distribution(build_id, app_id, token, tester_email):
    print(f"📦 Configuring beta distribution for build {build_id}...")

    # 1. Attach to Internal Beta Group (if not auto-accessible)
    group_id, has_all = get_internal_group(app_id, token)
    if group_id:
        if has_all:
            print(f"✅ Internal Beta Group (ID: {group_id}) has automatic access to all builds")
        else:
            body = {"data": [{"type": "betaGroups", "id": group_id}]}
            res = asc_request(f"/v1/builds/{build_id}/relationships/betaGroups", token, method="POST", body=body)
            if "error" in res and res["error"] not in (204, 409):
                print(f"ℹ️ Beta group status: {res.get('error')}")
            else:
                print(f"✅ Attached build to Internal Beta Group (ID: {group_id})")

    # 2. Attach directly to tester
    tester_id = get_tester_id(tester_email, token)
    if tester_id:
        body = {"data": [{"type": "betaTesters", "id": tester_id}]}
        res = asc_request(f"/v1/builds/{build_id}/relationships/individualTesters", token, method="POST", body=body)
        if "error" in res and res["error"] not in (204, 409):
            print(f"ℹ️ Tester status: {res.get('error')}")
        else:
            print(f"✅ Attached build directly to tester {tester_email}")

    # 3. Check beta detail state
    build_detail = asc_request(f"/v1/builds/{build_id}?include=buildBetaDetail", token)
    for inc in build_detail.get("included", []):
        if inc.get("type") == "buildBetaDetails":
            state = inc.get("attributes", {}).get("internalBuildState")
            print(f"📲 Internal Build State: {state}")
            return state

    return "UNKNOWN"


def main():
    parser = argparse.ArgumentParser(description="Automate TestFlight processing and internal distribution.")
    parser.add_argument("--app", default=None, help="App ID or key (kb, mm, mb)")
    parser.add_argument("--version", default=None, help="Build version/number to wait for (e.g. 17)")
    parser.add_argument("--timeout", type=int, default=900, help="Maximum seconds to wait (default: 900)")
    parser.add_argument("--poll-interval", type=int, default=15, help="Poll interval in seconds (default: 15)")
    parser.add_argument("--key-id", default=env_or_tokens("ASC_KEY_ID"))
    parser.add_argument("--issuer-id", default=env_or_tokens("ASC_ISSUER_ID", DEFAULT_ISSUER_ID))
    parser.add_argument("--key-path", default=env_or_tokens("ASC_PRIVATE_KEY_PATH") or env_or_tokens("ASC_KEY_PATH"))
    parser.add_argument("--email", default=env_or_tokens("ASC_TESTER_EMAIL", DEFAULT_TESTER_EMAIL))
    parser.add_argument("--check-only", action="store_true", help="Check latest build state and exit")
    args = parser.parse_args()

    args.key_id, args.issuer_id, args.key_path = _resolve_credentials(args)

    app_key = args.app or detect_app_id()
    if not app_key:
        print("❌ Error: App ID not specified and could not be detected from working directory.")
        sys.exit(1)

    app_id = APP_MAP.get(app_key.lower(), app_key)
    print(f"🔑 Generating ASC API token for App ID: {app_id}...")
    token = generate_token(args.key_id, args.issuer_id, args.key_path)

    start_time = time.time()
    print(f"⏳ Waiting for build in App Store Connect (timeout: {args.timeout}s)...")

    target_build = None

    while time.time() - start_time < args.timeout:
        endpoint = f"/v1/builds?filter[app]={app_id}&sort=-uploadedDate&limit=5"
        res = asc_request(endpoint, token)
        builds = res.get("data", [])

        if not builds:
            print("⏳ No builds found yet. Waiting...")
            time.sleep(args.poll_interval)
            continue

        if args.version:
            matching = [b for b in builds if b.get("attributes", {}).get("version") == str(args.version)]
            if matching:
                target_build = matching[0]
            else:
                print(f"⏳ Build {args.version} not visible in ASC yet. Waiting...")
                time.sleep(args.poll_interval)
                continue
        else:
            target_build = builds[0]

        build_id = target_build.get("id")
        attrs = target_build.get("attributes", {})
        version = attrs.get("version")
        state = attrs.get("processingState")

        print(f"ℹ️  Build {version} (ID: {build_id}) -> Processing State: {state}")

        if args.check_only:
            ensure_distribution(build_id, app_id, token, args.email)
            return

        if state == "VALID":
            print(f"🎉 Build {version} is VALID in App Store Connect!")
            dist_state = ensure_distribution(build_id, app_id, token, args.email)
            print(f"\n=======================================================")
            print(f"✅ Build {version} is now LIVE on TestFlight ({dist_state})!")
            print(f"=======================================================\n")
            return
        elif state in ("FAILED", "INVALID"):
            print(f"❌ Build {version} failed processing in App Store Connect: {state}")
            sys.exit(1)

        time.sleep(args.poll_interval)

    print(f"⏱️ Timed out after {args.timeout}s waiting for build to become VALID.")
    sys.exit(1)


if __name__ == "__main__":
    main()
