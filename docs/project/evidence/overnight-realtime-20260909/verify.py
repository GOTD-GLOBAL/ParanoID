"""Offline, read-only validation of preserved reviewed source and evidence."""
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]


def digest(path):
    assert path.is_file() and not path.is_symlink(), path
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(name):
    return json.loads((HERE / name).read_text())


def main():
    assert digest(HERE / 'final-source-sha256.json') == (
        '0f6d0689cefd7eac1a61bddc296054fbddc09dc0d06795a832779f785c314f2e'
    )
    assert digest(HERE / 'postdeployment-docs-sha256.json') == (
        '6522b7fa39c1507dfba300ad97e37b815d58be81fda7e01905858eb95835c415'
    )
    manifest = load('final-source-sha256.json')
    docs = load('postdeployment-docs-sha256.json')
    changed = []
    for name, expected in manifest.items():
        actual = digest(ROOT / name)
        if actual != expected:
            assert name.endswith('.md') and actual == docs[name], name
            assert digest(HERE / 'frozen-docs' / (name + '.txt')) == expected, name
            changed.append(name)
    for name, expected in docs.items():
        assert digest(ROOT / name) == expected, name
    for name, record in load('copy-provenance.json').items():
        assert digest(HERE / name) == record['sha256'], name
    print(json.dumps({
        'result': 'PASS', 'source_entries': len(manifest),
        'non_markdown_inputs_unchanged': True,
        'postbuild_markdown_changes': changed,
        'postbuild_document_entries': len(docs),
        'frozen_source_reconstructable': True,
        'copied_evidence_hashes_match': True,
    }, indent=2))


if __name__ == '__main__':
    main()
