#!/usr/bin/env python3
"""Scenario parity between the Android call smoke and the iOS controller tests.

Offline and source-only: it reads two files and compares the scenarios they
name. The Android smoke ``clients/android/test/CallControllerSmoke.java`` states
every rule of the call state machine as ``check(<condition>, "<label>")``, and
the label is the rule in words. This gate requires every one of those labels to
appear inside a Swift string literal of
``clients/ios/ParanoidKit/Tests/ParanoidKitTests/CallControllerTests.swift`` —
that is, as the message of the assertion that mirrors it — so that a scenario
the two phones disagree about cannot be silently dropped from the iOS side.

Two things it deliberately does **not** claim:

* It does not check that the Swift assertion tests the same thing; only
  ``swift test`` can say that. It checks that the scenario is named and
  therefore accounted for.
* A label may be embedded in a longer message rather than standing alone. That
  is how a genuine divergence is recorded: the description size, where the
  core's ``MAX_SDP`` is 12288 bytes but this client is held to the 9000-byte
  frame budget, keeps the Android label and says what decides it here. The
  summary line counts those separately so the divergence stays visible.

Comments are stripped before the Swift literals are read, so a label pasted
into a comment does not stand in for an assertion.

Run: ``python3 clients/ios/test_call_controller_parity.py`` →
``labels: N/N covered``.

Exit codes:
  0  every Android label is named by a Swift assertion
  1  at least one label has no Swift assertion (each one is listed)
  2  a source file is missing or yields no labels at all (never a vacuous PASS)
"""
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
ANDROID = HERE.parent / 'android' / 'test' / 'CallControllerSmoke.java'
SWIFT = HERE / 'ParanoidKit' / 'Tests' / 'ParanoidKitTests' / 'CallControllerTests.swift'

# `check(<condition>, "<label>");` on one line. The helper's own declaration
# carries no literal and is not matched.
CHECK = re.compile(r'check\([^;\n]*?,\s*"((?:[^"\\\n]|\\.)*)"\s*\)\s*;')
# A Swift string literal on one line, the same shape `test_ui_contract.py` reads.
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
# A smoke with fewer scenarios than this is a smoke that was not read properly.
MINIMUM_LABELS = 60


def unavailable(message):
    print(f'ERROR: {message}', file=sys.stderr)
    sys.exit(2)


def read(path, label):
    if not path.is_file():
        unavailable(f'{label} is missing: {path}')
    return path.read_text()


def strip_comments(source):
    """`source` with `//` and `/* */` comments blanked out.

    String literals are walked through rather than around, so a `//` inside one
    never starts a comment and a quote inside a comment never starts a string.
    """
    out = []
    index, length = 0, len(source)
    while index < length:
        character = source[index]
        if character == '"':
            out.append(character)
            index += 1
            while index < length and source[index] != '"':
                if source[index] == '\\' and index + 1 < length:
                    out.append(source[index])
                    index += 1
                if source[index] == '\n':
                    break
                out.append(source[index])
                index += 1
            if index < length:
                out.append(source[index])
                index += 1
            continue
        if source.startswith('//', index):
            while index < length and source[index] != '\n':
                index += 1
            continue
        if source.startswith('/*', index):
            end = source.find('*/', index + 2)
            index = length if end < 0 else end + 2
            continue
        out.append(character)
        index += 1
    return ''.join(out)


def main():
    java = read(ANDROID, 'the Android smoke')
    swift = read(SWIFT, 'the iOS controller tests')
    labels = []
    for label in CHECK.findall(java):
        if label not in labels:
            labels.append(label)
    if len(labels) < MINIMUM_LABELS:
        unavailable(f'only {len(labels)} labels read from {ANDROID.name}; '
                    'the smoke changed shape and this gate must be updated')
    messages = LITERAL.findall(strip_comments(swift))
    verbatim, embedded, missing = 0, [], []
    for label in labels:
        if label in messages:
            verbatim += 1
        elif any(label in message for message in messages):
            embedded.append(label)
        else:
            missing.append(label)
    for label in embedded:
        print(f'embedded: {label!r} is named inside a longer iOS message')
    for label in missing:
        print(f'uncovered: {label!r} has no iOS assertion')
    covered = verbatim + len(embedded)
    if missing:
        print(f'FAIL: labels: {covered}/{len(labels)} covered, {len(missing)} uncovered')
        return 1
    print(f'labels: {covered}/{len(labels)} covered '
          f'({verbatim} verbatim, {len(embedded)} embedded)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
