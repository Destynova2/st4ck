#!/usr/bin/env python3
"""Explicit Woodpecker 3.x repository activation with a private token file.

Uses only the Python standard library. Activation does not prove webhook
delivery or successful pipeline execution, and never injects deployment secrets.
"""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import sys
from urllib import error, parse, request


class Refused(RuntimeError):
    pass


class HTTPFailure(Refused):
    def __init__(self, status):
        self.status = status
        super().__init__(f"Woodpecker API returned HTTP {status}; check identity, permissions and server configuration")


def require(condition, message):
    if not condition:
        raise Refused(message)


def server_url(value):
    require(not any(c.isspace() or ord(c) < 32 for c in value), "Invalid server URL")
    try:
        url = parse.urlsplit(value)
        require(url.hostname and not url.username and not url.password
                and not url.query and not url.fragment, "Invalid server URL")
        require(url.port is None or 0 < url.port < 65536, "Invalid server port")
        loopback = url.hostname == "localhost"
        try:
            loopback = loopback or ipaddress.ip_address(url.hostname).is_loopback
        except ValueError:
            pass
        require(url.scheme == "https" or url.scheme == "http" and loopback,
                "Use HTTPS or an HTTP loopback tunnel; remote plaintext tokens are refused")
    except ValueError:
        raise Refused("Invalid server URL") from None
    return value.rstrip("/")


def read_token(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                    and not info.st_mode & 0o077, "Token file must be owned by you, regular and private (0600 or 0400)")
            raw = stream.read(8193)
        require(len(raw) <= 8192, "Token file is too large")
        token = raw.decode("ascii").strip()
        require(token and all(33 <= ord(c) <= 126 for c in token), "Token file must contain one nonempty ASCII token")
        return token
    except (OSError, UnicodeError):
        raise Refused("Cannot read private token file (symlinks are refused)") from None


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class API:
    def __init__(self, url, token, timeout=20):
        self.url = server_url(url)
        self.token = token
        self.timeout = timeout
        self.opener = request.build_opener(request.ProxyHandler({}), NoRedirect())

    def call(self, method, path, *, empty=False):
        req = request.Request(self.url + path, method=method,
                              data=b"" if method == "POST" else None,
                              headers={"Authorization": "Bearer " + self.token, "Accept": "application/json"})
        try:
            with self.opener.open(req, timeout=self.timeout) as response:
                require(response.status == (204 if empty else 200), "Unexpected Woodpecker API response status")
                raw = response.read(4 * 1024 * 1024 + 1)
            require(len(raw) <= 4 * 1024 * 1024, "Woodpecker API response exceeds size limit")
            if empty:
                require(not raw, "Expected an empty Woodpecker response")
                return None
            return json.loads(raw)
        except error.HTTPError as exc:
            exc.close()
            raise HTTPFailure(exc.code) from None
        except (OSError, error.URLError, ValueError):
            # Error bodies and exception URLs can contain credentials. Never echo them.
            raise Refused("Woodpecker API connection failed or returned invalid JSON") from None


def activate(api, name, repair=False):
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", name)
            and all(part not in (".", "..") for part in name.split("/")),
            "Repository must be owner/name")
    user = api.call("GET", "/api/user")
    require(isinstance(user, dict) and isinstance(user.get("login"), str) and user["login"]
            and type(user.get("forge_id")) is int and user["forge_id"] > 0,
            "Cannot verify authenticated Woodpecker forge identity")
    repos = api.call("GET", "/api/user/repos?all=true")
    require(isinstance(repos, list) and all(isinstance(repo, dict) for repo in repos),
            "Invalid repository list from Woodpecker")
    matches = [repo for repo in repos if repo.get("full_name") == name]
    require(len(matches) == 1, "Repository is missing or ambiguous; check the logged-in forge account and permissions")
    selected = matches[0]
    remote_id = selected.get("forge_remote_id")
    require(isinstance(remote_id, str) and remote_id.strip(), "Missing forge repository ID")
    require(selected.get("forge_id", user["forge_id"]) == user["forge_id"]
            and not selected.get("has_forge_name_conflict") and not selected.get("has_no_forge_repo"),
            "Repository forge identity is stale or conflicting")
    require(type(selected.get("active")) is bool, "Missing repository activation status")
    if not selected["active"]:
        try:
            api.call("POST", "/api/repos?" + parse.urlencode({"forge_remote_id": remote_id}))
        except HTTPFailure as exc:
            if exc.status != 409:
                raise
            # A concurrent activation is safe only if the independent lookup agrees.

    def verify():
        repo = api.call("GET", "/api/repos/lookup/" + parse.quote(name, safe="/"))
        require(isinstance(repo, dict) and repo.get("full_name") == name
                and repo.get("forge_remote_id") == remote_id and repo.get("forge_id") == user["forge_id"]
                and repo.get("active") is True and type(repo.get("id")) is int and repo["id"] > 0,
                "Repository activation could not be verified against the selected forge identity")
        return repo["id"]

    repo_id = verify()
    if repair:
        api.call("POST", f"/api/repos/{repo_id}/repair", empty=True)
        require(verify() == repo_id, "Repository identity changed during webhook repair")
    return {"repository": name, "repository_id": repo_id, "active": True,
            "webhook_repaired": repair, "pipeline_execution": "not_verified"}


def main(argv=None):
    parser = argparse.ArgumentParser(prog="woodpecker-activate", description=__doc__)
    parser.add_argument("--server-url", required=True, type=server_url)
    parser.add_argument("--repo", required=True, help="Exact forge owner/name")
    parser.add_argument("--token-file", required=True, type=Path)
    parser.add_argument("--repair", action="store_true", help="Re-register the webhook using the server's configured webhook host")
    args = parser.parse_args(argv)
    result = activate(API(args.server_url, read_token(args.token_file)), args.repo, args.repair)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Refused as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
