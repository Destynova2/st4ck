"""Air-gap images must follow the deployed plugin pin without a duplicate."""

import importlib.util
from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("hauler", ROOT / "scripts/hauler-manifest-gen.py")
hauler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hauler)


class HaulerImageTests(unittest.TestCase):
    def test_velero_plugin_comes_from_deployed_values(self):
        values = yaml.safe_load((ROOT / "stacks/storage/flux/values-velero.yaml").read_text())
        plugin = next(c["image"] for c in values["initContainers"] if c["name"] == "velero-plugin-for-aws")
        generated = [image for image in hauler.collect_images() if "velero-plugin-for-aws:" in image]
        self.assertEqual(generated, [plugin])
        self.assertNotIn("velero-plugin-for-aws:", (ROOT / "scripts/mirror-images.txt").read_text())
        docs = list(yaml.safe_load_all((ROOT / "hauler-manifest.yaml").read_text()))
        bundled = [image["name"] for doc in docs if doc["kind"] == "Images" for image in doc["spec"]["images"]
                   if "velero-plugin-for-aws:" in image["name"]]
        self.assertEqual(bundled, [plugin])


if __name__ == "__main__":
    unittest.main()
