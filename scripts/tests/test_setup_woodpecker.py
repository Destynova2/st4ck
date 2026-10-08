"""Woodpecker activation regressions. All HTTP requests are mocked."""

from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("setup_woodpecker", ROOT / "scripts/setup-woodpecker.py")
wp = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wp)
TOKEN = "unit-test-secret-never-print"
USER = {"login": "talos", "forge_id": 7}
REPO = {"full_name": "talos/talos", "forge_id": 7, "forge_remote_id": "283", "active": False}
ACTIVE = dict(REPO, active=True, id=49)


class Response(io.BytesIO):
    def __init__(self, data, status=200):
        super().__init__(json.dumps(data).encode() if not isinstance(data, bytes) else data)
        self.status = status


class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.opener = Mock()
        self.mock = patch.object(wp.request, "build_opener", return_value=self.opener)
        self.mock.start()
        self.addCleanup(self.mock.stop)
        self.api = wp.API("http://127.0.0.1:18000", TOKEN)

    def responses(self, *values):
        self.opener.open.side_effect = [value if isinstance(value, Exception) else Response(value) for value in values]

    def calls(self):
        return [(call.args[0].method, call.args[0].full_url) for call in self.opener.open.call_args_list]

    def test_discovers_real_forge_id_and_verifies_activation(self):
        self.responses(USER, [dict(REPO, full_name="another/repo", forge_remote_id="1"), REPO], ACTIVE, ACTIVE)
        result = wp.activate(self.api, "talos/talos")
        self.assertEqual(result["repository_id"], 49)
        self.assertEqual(result["pipeline_execution"], "not_verified")
        self.assertEqual(self.calls(), [("GET", self.api.url + "/api/user"),
                                       ("GET", self.api.url + "/api/user/repos?all=true"),
                                       ("POST", self.api.url + "/api/repos?forge_remote_id=283"),
                                       ("GET", self.api.url + "/api/repos/lookup/talos/talos")])
        for call in self.opener.open.call_args_list:
            self.assertEqual(call.args[0].get_header("Authorization"), "Bearer " + TOKEN)
            self.assertNotIn(TOKEN, call.args[0].full_url)
            self.assertEqual(call.kwargs["timeout"], 20)

    def test_already_active_is_read_only(self):
        self.responses(USER, [ACTIVE], ACTIVE)
        wp.activate(self.api, "talos/talos")
        self.assertTrue(all(method == "GET" for method, _ in self.calls()))

    def test_explicit_repair_uses_discovered_woodpecker_id(self):
        self.opener.open.side_effect = [Response(USER), Response([ACTIVE]), Response(ACTIVE),
                                        Response(b"", 204), Response(ACTIVE)]
        self.assertTrue(wp.activate(self.api, "talos/talos", repair=True)["webhook_repaired"])
        self.assertEqual(self.calls()[-2], ("POST", self.api.url + "/api/repos/49/repair"))

    def test_inactive_forge_repo_may_omit_forge_id(self):
        inactive = dict(REPO)
        del inactive["forge_id"]
        self.responses(USER, [inactive], ACTIVE, ACTIVE)
        wp.activate(self.api, "talos/talos")

    def test_409_requires_positive_independent_lookup(self):
        for lookup in (ACTIVE, dict(ACTIVE, forge_remote_id="999"), dict(ACTIVE, active=False)):
            with self.subTest(lookup=lookup):
                conflict = HTTPError("hidden", 409, TOKEN, {}, io.BytesIO(TOKEN.encode()))
                self.responses(USER, [REPO], conflict, lookup)
                if lookup == ACTIVE:
                    wp.activate(self.api, "talos/talos")
                else:
                    with self.assertRaises(wp.Refused):
                        wp.activate(self.api, "talos/talos")

    def test_missing_ambiguous_stale_or_wrong_forge_refuses_without_mutation(self):
        for repos in ([], [REPO, REPO], [dict(REPO, forge_id=99)],
                      [dict(REPO, has_forge_name_conflict=True)], [dict(REPO, has_no_forge_repo=True)],
                      [dict(REPO, forge_remote_id="")], [dict(REPO, active="false")], {"repos": [REPO]}):
            with self.subTest(repos=repos):
                self.opener.reset_mock()
                self.responses(USER, repos)
                with self.assertRaises(wp.Refused):
                    wp.activate(self.api, "talos/talos")
                self.assertTrue(all(method == "GET" for method, _ in self.calls()))

    def test_post_failure_does_not_fall_through_to_success(self):
        for status in (401, 403, 500, 302):
            self.opener.reset_mock()
            self.responses(USER, [REPO], HTTPError("hidden", status, TOKEN, {}, io.BytesIO(TOKEN.encode())))
            with self.assertRaises(wp.Refused) as caught:
                wp.activate(self.api, "talos/talos")
            self.assertNotIn(TOKEN, str(caught.exception))
            self.assertEqual(len(self.calls()), 3)

    def test_wrong_final_identity_is_not_success(self):
        for change in ({"id": 0}, {"id": True}, {"forge_id": 2}, {"full_name": "evil/repo"},
                       {"forge_remote_id": "1"}, {"active": False}):
            self.responses(USER, [REPO], ACTIVE, dict(ACTIVE, **change))
            with self.assertRaises(wp.Refused):
                wp.activate(self.api, "talos/talos")

    def test_invalid_api_responses_and_transport_are_sanitized(self):
        for response in (Response(TOKEN.encode()), Response(b"x" * (4 * 1024 * 1024 + 1)),
                         Response({}, 201), URLError(TOKEN)):
            self.opener.open.side_effect = [response]
            with self.assertRaises(wp.Refused) as caught:
                self.api.call("GET", "/api/user")
            self.assertNotIn(TOKEN, str(caught.exception))

    def test_repository_input_never_changes_api_path(self):
        for repo in ("../talos", "talos/..", "talos/name?x=y", "owner/repo/extra", "owner\n/repo"):
            with self.assertRaises(wp.Refused):
                wp.activate(self.api, repo)
        self.opener.open.assert_not_called()

    def test_redirects_cannot_forward_bearer_token(self):
        self.assertIsNone(wp.NoRedirect().redirect_request(None, None, 302, "", {}, "https://elsewhere.invalid"))

    def test_cli_requires_token_file_and_prints_only_sanitized_result(self):
        with tempfile.TemporaryDirectory() as directory:
            token = Path(directory) / "token"
            token.write_text(TOKEN)
            token.chmod(0o600)
            self.responses(USER, [ACTIVE], ACTIVE)
            output = io.StringIO()
            with redirect_stdout(output):
                wp.main(["--server-url", self.api.url, "--repo", "talos/talos", "--token-file", str(token)])
            self.assertNotIn(TOKEN, output.getvalue())
            self.assertEqual(json.loads(output.getvalue())["active"], True)


class TokenTests(unittest.TestCase):
    def test_private_regular_token_and_trailing_newline(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token"
            path.write_text(TOKEN + "\n")
            for mode in (0o600, 0o400):
                path.chmod(mode)
                self.assertEqual(wp.read_token(path), TOKEN)

    def test_public_symlink_missing_empty_and_multiline_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token"
            path.write_text(TOKEN)
            path.chmod(0o644)
            with self.assertRaises(wp.Refused):
                wp.read_token(path)
            path.chmod(0o600)
            link = Path(directory) / "link"
            link.symlink_to(path)
            for bad in (link, path.parent / "missing", path.parent):
                with self.assertRaises(wp.Refused):
                    wp.read_token(bad)
            for bad in (b"", b"one\ntwo", b"non ascii \xff", b"a" * 8193):
                path.write_bytes(bad)
                with self.assertRaises(wp.Refused):
                    wp.read_token(path)

    def test_plaintext_remote_and_url_credentials_refused(self):
        for url in ("http://remote.invalid", "http://192.0.2.1", "https://u:p@host.invalid",
                    "https://host.invalid?q=token", "https://host.invalid#fragment", "https://host.invalid:99999",
                    "https://host.invalid\n", "file:///tmp/server"):
            with self.assertRaises(wp.Refused):
                wp.server_url(url)
        for url in ("http://127.0.0.1:18000", "http://[::1]:8000", "https://host.invalid/ci"):
            self.assertEqual(wp.server_url(url), url)


if __name__ == "__main__":
    unittest.main()
