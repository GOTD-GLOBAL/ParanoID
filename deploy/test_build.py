"""REQ-DEPLOY-001: public package contains only the intended regular files."""
import importlib.util
import json
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('builder', HERE / 'build.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
SOURCES = {'paranoid-server': 'server/target/release/paranoid-server',
           'schema.sql': 'server/schema.sql', 'alpha.py': 'deploy/alpha.py',
           'create-test-tls.py': 'scripts/create-test-tls.py', 'README.md': 'deploy/README.md'}


class BuildTests(unittest.TestCase):
    def test_symlink_component_rejected_without_publishing(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-build-test-') as tmp:
            root = Path(tmp)
            for name, source in SOURCES.items():
                path = root / source
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('synthetic ' + name)
            source = root / SOURCES['schema.sql']
            source.rename(source.with_suffix('.real'))
            source.symlink_to(source.with_suffix('.real'))
            with patch.object(builder, 'ROOT', root), patch.object(builder.subprocess, 'run'), \
                    patch.object(builder.subprocess, 'check_output', return_value=b'fixture\n'), \
                    self.assertRaises((ValueError, OSError)):
                builder.main()
            self.assertEqual(list((root / 'dist').rglob('*.tar')), [])

    def test_stale_secrets_never_archived_or_deleted(self):
        with tempfile.TemporaryDirectory(prefix='paranoid-build-test-') as tmp:
            root = Path(tmp)
            for name, source in SOURCES.items():
                path = root / source
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('synthetic ' + name)
            stale = root / 'dist/release/config.json'
            stale.parent.mkdir(parents=True)
            stale.write_text('SYNTHETIC_SECRET_MARKER')
            (stale.parent / 'tls').mkdir()
            (stale.parent / 'tls/key').write_text('SYNTHETIC_PRIVATE_KEY')
            with patch.object(builder, 'ROOT', root), patch.object(builder.subprocess, 'run'), \
                    patch.object(builder.subprocess, 'check_output', return_value=b'fixture\n'):
                builder.main()  # Only cargo/toolchain/git mocked; real copying and archiving.
            artifact, = (root / 'dist').rglob('*.tar')
            with tarfile.open(artifact) as archive:
                self.assertEqual(set(archive.getnames()), {'release/' + n for n in (*SOURCES, 'manifest.json')})
                self.assertTrue(all(m.isfile() for m in archive.getmembers()))
                manifest = json.load(archive.extractfile('release/manifest.json'))
                self.assertEqual(set(manifest['sha256']), set(SOURCES))
            self.assertEqual(stale.read_text(), 'SYNTHETIC_SECRET_MARKER')
            self.assertEqual((stale.parent / 'tls/key').read_text(), 'SYNTHETIC_PRIVATE_KEY')


if __name__ == '__main__':
    unittest.main()
