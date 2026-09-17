"""Execute the actual workflow boundary step in disposable Git repositories."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def boundary_step():
    text = (ROOT / '.github/workflows/ios.yml').read_text()
    step = text.split('      - name: Component boundary against the pull request base', 1)[1]
    run = step.split('        run:', 1)[1]
    if not run.startswith(' |'):
        return run.strip()
    return '\n'.join(line[10:] for line in run.splitlines()[1:] if line.startswith('          '))


class BoundaryScope(unittest.TestCase):
    def test_workflow_limits_strict_gate_to_declared_ios_prs(self):
        text = (ROOT / '.github/workflows/ios.yml').read_text()
        step = text.split('      - name: Component boundary against the pull request base', 1)[1]
        conditions = [line.strip() for line in step.splitlines() if line.strip().startswith('if:')]
        self.assertEqual(conditions, ["if: github.event_name == 'pull_request' && startsWith(github.head_ref, 'feat/ios-')"])
        self.assertIn('python3 tools/test_ios_boundary_scope.py', text)
        # This source contract checks applicability; cases below execute the real
        # shell body for an applicable iOS-only branch, not the GitHub evaluator.

    def run_case(self, changes, base_missing=False):
        with tempfile.TemporaryDirectory(prefix='paranoid-ci-boundary-') as tmp:
            root = Path(tmp)
            def git(*args):
                return subprocess.check_output(['git', '-C', str(root), *args], text=True, stderr=subprocess.STDOUT).strip()
            git('init', '-q')
            git('config', 'user.name', 'Synthetic test')
            git('config', 'user.email', 'synthetic@example.invalid')
            gate = root/'clients/ios/test_component_boundary.py'
            gate.parent.mkdir(parents=True)
            gate.write_bytes((ROOT/'clients/ios/test_component_boundary.py').read_bytes())
            git('add', '.')
            git('commit', '-qm', 'synthetic base')
            base = git('rev-parse', 'HEAD')
            for name in changes:
                path = root/name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('synthetic change\n')
            git('add', '.')
            git('commit', '-qm', 'synthetic candidate')
            env = dict(os.environ, BASE_SHA='does-not-exist' if base_missing else base)
            return subprocess.run(['bash', '-e', '-c', boundary_step()], cwd=root, env=env, text=True, capture_output=True)

    def test_android_only_is_not_an_ios_component_change(self):
        result = self.run_case(['clients/android/example.java', 'docs/example.md'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('NOT_APPLICABLE', result.stdout)

    def test_ios_only_still_runs_strict_gate(self):
        result = self.run_case(['clients/ios/example.swift'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS:', result.stdout)
        self.assertNotIn('NOT_APPLICABLE', result.stdout)

    def test_mixed_ios_android_is_still_rejected(self):
        result = self.run_case(['clients/ios/example.swift', 'clients/android/example.java'])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('forbidden: clients/android/', result.stdout)

    def test_unresolved_base_never_skips(self):
        result = self.run_case(['clients/android/example.java'], base_missing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('NOT_APPLICABLE', result.stdout)


if __name__ == '__main__':
    unittest.main()
