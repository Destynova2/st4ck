"""Keep the bootstrap launcher compatible with local and remote Podman."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PodmanKubePlayTests(unittest.TestCase):
    def run_launcher(self, help_text, help_status=0):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "podman"
            fake.write_text("""#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:] == ['kube', 'play', '--help']:
    print(os.environ['HELP_TEXT'])
    sys.exit(int(os.environ['HELP_STATUS']))
print(json.dumps(sys.argv[1:]))
""")
            fake.chmod(0o755)
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                       HELP_TEXT=help_text, HELP_STATUS=str(help_status))
            return subprocess.run(["bash", str(ROOT / "scripts/podman-kube-play.sh"),
                                   "--replace", "/private/test manifest.yaml"],
                                  env=env, text=True, capture_output=True, timeout=10)

    def test_local_engine_disables_implicit_build(self):
        result = self.run_launcher("Options: --build --replace")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout),
                         ["kube", "play", "--build=false", "--replace", "/private/test manifest.yaml"])

    def test_remote_client_omits_unsupported_build_flag(self):
        result = self.run_launcher("Options: --replace")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout),
                         ["kube", "play", "--replace", "/private/test manifest.yaml"])

    def test_failed_capability_check_does_not_launch(self):
        result = self.run_launcher("", help_status=125)
        self.assertEqual(result.returncode, 125)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
