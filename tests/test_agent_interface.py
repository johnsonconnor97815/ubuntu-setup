import io
import json
import os
import subprocess
import tempfile
from contextlib import redirect_stdout
from pathlib import Path
import unittest

from ubuntu_setup.cli import main


ROOT = Path(__file__).resolve().parents[1]


class AgentInterfaceTests(unittest.TestCase):
    def test_capabilities_expose_the_host_contract(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = main(["capabilities", "--format", "json"])

        self.assertEqual(code, 0)
        result = json.loads(out.getvalue())
        interface = result["agent_interface"]
        self.assertEqual(interface["schema_version"], 1)
        self.assertEqual(interface["working_directory"], "ubuntu-setup 仓库根目录")
        self.assertIn("--no-open", interface["commands"]["inspect"])
        self.assertIn("--online", interface["commands"]["inspect_online"])
        self.assertIn("unknown 是有效结果", "".join(interface["result_policy"]))
        self.assertIn("只读", interface["authorization"])

    def test_generic_skill_and_bootstrap_deploy_the_same_entry(self):
        skill = (ROOT / "skills/ubuntu-inspect/SKILL.md").read_text()
        bootstrap = (ROOT / "bootstrap.sh").read_text()

        self.assertIn("name: ubuntu-inspect", skill)
        self.assertIn("./ubuntu-setup runtime status --format json", skill)
        self.assertIn("./ubuntu-setup capabilities --format json", skill)
        self.assertIn("./ubuntu-setup inspect --format json --no-open", skill)
        self.assertIn("Exit code `2`", skill)
        self.assertIn("`unknown` means information is missing", skill)
        self.assertIn("ubuntu-inspect", bootstrap)

    def test_bootstrap_deploys_current_codex_skill_and_legacy_prompt(self):
        with tempfile.TemporaryDirectory() as home:
            environment = dict(os.environ, HOME=home)
            subprocess.run(
                ["bash", "-c", "source ./bootstrap.sh; deploy_skills"],
                cwd=ROOT,
                env=environment,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            skill = Path(home) / ".agents/skills/ubuntu-inspect/SKILL.md"
            prompt = Path(home) / ".codex/prompts/ubuntu-inspect.md"
            skill_text = skill.read_text()
            prompt_text = prompt.read_text()

        self.assertIn("name: ubuntu-inspect", skill_text)
        self.assertNotIn("---\n", prompt_text)
        self.assertIn("# Ubuntu Inspect", prompt_text)


if __name__ == "__main__":
    unittest.main()
