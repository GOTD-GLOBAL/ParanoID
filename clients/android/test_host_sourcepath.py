#!/usr/bin/env python3
"""Host javac -sourcepath contract for the CI compiles of the Android text client.

The CI host compiles (`server.yml`, test_realtime_transport.py, test_updates.py)
pass `-sourcepath clients/android/src`. A production class of the same package
that is missing from a hand-written file list then compiles implicitly instead
of failing CI. That was the most common CI failure in 2026-09/10, and it was
noise, not a defect. The sourcepath holds the production text package only, so
a new dependency of `org.paranoid.text` on `org.paranoid.devnet` still fails
the build. That failure is real: the text client must not need the devnet
client to compile.

Offline: javac only, the pinned org.json jar from dependencies.py, no network.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
SRC = ROOT / 'src'
DEVNET_SRC = ROOT.parent / 'android-devnet' / 'src'
JSON_JAR = ROOT / 'out/deps/json-20240303.jar'


def javac(*sources, sourcepath=(SRC,)):
    with tempfile.TemporaryDirectory(prefix='paranoid-sourcepath-') as out:
        result = subprocess.run(
            ['javac', '--release', '8', '-Xlint:-options', '-encoding', 'UTF-8',
             '-sourcepath', os.pathsep.join(map(str, sourcepath)),
             '-cp', str(JSON_JAR), '-d', out, *map(str, sources)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        classes = {path.stem for path in Path(out).rglob('*.class') if '$' not in path.stem}
        return result.returncode, result.stdout, classes


class HostSourcepath(unittest.TestCase):
    def setUp(self):
        self.assertTrue(JSON_JAR.is_file(), 'run clients/android/dependencies.py first')

    def test_same_package_dependencies_compile_without_a_list(self):
        # SelfServiceClient alone: every same-package class it needs, such as
        # IdentityPorts, KeyClient and SyncCycle, comes from the sourcepath.
        code, output, classes = javac(SRC / 'org/paranoid/text/SelfServiceClient.java')
        self.assertEqual(code, 0, output)
        self.assertTrue({'SelfServiceClient', 'IdentityPorts', 'KeyClient'} <= classes, classes)

    def test_text_package_still_cannot_depend_on_devnet(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-boundary-') as directory:
            probe = Path(directory) / 'org/paranoid/text/BoundaryProbe.java'
            probe.parent.mkdir(parents=True)
            probe.write_text('package org.paranoid.text;\n'
                             'import org.paranoid.devnet.IdentityLogin;\n'
                             'final class BoundaryProbe { IdentityLogin login; }\n')
            code, output, _ = javac(probe)
            self.assertNotEqual(code, 0, 'text -> devnet must not resolve from the text sourcepath')
            self.assertIn('package org.paranoid.devnet does not exist', output)
            # Control: the same probe compiles once devnet is deliberately added.
            code, output, _ = javac(probe, sourcepath=(SRC, DEVNET_SRC))
            self.assertEqual(code, 0, output)


if __name__ == '__main__':
    unittest.main()
