"""REQ-CALL-006: offline package integrity and relocation; no network tests."""
import json
from pathlib import Path
import tempfile
import unittest

import package


class PackageTests(unittest.TestCase):
    def test_manifest_binds_exact_regular_members_and_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'runtime.py').write_text('fixture content\n')
            package.write_manifest(root, {'upstream': 'fixture', 'acceptance': 'NOT RUN'})
            package.verify(root)
            (root / 'extra').write_text('unexpected')
            with self.assertRaises(ValueError):
                package.verify(root)
            (root / 'extra').unlink()
            (root / 'runtime.py').write_text('changed')
            with self.assertRaises(ValueError):
                package.verify(root)
            (root / 'runtime.py').unlink()
            (root / 'runtime.py').symlink_to('/dev/null')
            with self.assertRaises(ValueError):
                package.verify(root)

    def test_archive_rejects_traversal_links_and_unexpected_members(self):
        import io
        import tarfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for index, name in enumerate(('../outside', '/absolute', 'release/../outside')):
                archive = root / str(index)
                with tarfile.open(archive, 'w') as tar:
                    member = tarfile.TarInfo(name)
                    member.size = 1
                    tar.addfile(member, io.BytesIO(b'x'))
                with self.assertRaises(ValueError):
                    package.extract(archive, root / ('out' + str(index)))


if __name__ == '__main__':
    unittest.main()
