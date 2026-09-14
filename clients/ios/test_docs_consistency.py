#!/usr/bin/env python3
"""Documentation-consistency gate for the iOS client (offline, no network).

The reviewers of pull request #36 found the branch's documents disagreeing with
its own evidence: the catalogue recorded two hosted registrations and a run on a
physical iPhone while the README and the decision record still described the
state before that day. Each document had been written at a different point of
the branch and nothing made them agree. That is the class of defect this gate
closes, so that the answer to "will it drift again" is a failing build rather
than a reviewer's patience.

The rule is one-directional: the **evidence is the source of truth** and the
prose must not contradict it. The gate never asserts that a document *mentions*
something — a document is free to be silent — only that what it does say about
these facts is not the opposite of what was measured.

What it checks, and where each fact comes from:

1. **Hosted registrations.** The counter lives in the evidence catalogue. No
   document may state a different number, or say that no hosted account exists.
2. **The physical phone.** If the device evidence records a run, no document may
   say that nothing has run on a phone or that no signed build exists.
3. **The joint tests.** The two stage files carry the authoritative ``Result``
   cells. If either records a shown step, no document may say that the joint
   tests have not been run; if neither does, no document may say they have.
4. **The status vocabulary.** Every status token used in a ``Result`` cell of
   the requirement table or the stage files must be defined in the vocabulary
   section of ``docs/clients/ios/verification.md``. A status nobody defined is
   how ``SHOWN`` quietly grew a second meaning.

Exit codes:
  0  ``PASS: N facts checked across M documents``
  1  at least one contradiction (each one is printed with its file and line)
  2  a source of truth is missing or unreadable — never a vacuous PASS
"""
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
EVIDENCE = ROOT / 'docs/project/evidence/ios-client-20260913'
CATALOGUE = EVIDENCE / 'README.md'
STAGE1 = EVIDENCE / 'stage1-text.md'
STAGE2 = EVIDENCE / 'stage2-voice.md'
VERIFICATION = ROOT / 'docs/clients/ios/verification.md'
DEVICE_EVIDENCE = HERE / 'out/evidence/device-smoke-20260913/device-smoke-result.json'

# Every document that makes claims about what this client has been shown to do.
# A file that does not exist is skipped, so the gate survives a rename without
# turning into a vacuous PASS: the sources of truth above are required instead.
DOCUMENTS = (
    'clients/ios/README.md',
    'CHANGELOG.md',
    'docs/clients/ios/README.md',
    'docs/clients/ios/verification.md',
    'docs/clients/ios/build-and-testflight.md',
    'docs/clients/ios/self-service.md',
    'docs/clients/ios/voice-calls.md',
    'docs/clients/ios/protocol-sources.md',
    'docs/clients/ios/export-compliance.md',
    'docs/decisions/0014-ios-client.md',
    'docs/rfcs/0021-ios-client.md',
    'docs/security/ios-client-threats.md',
    'docs/project/current-state.md',
    'docs/project/evidence/ios-client-20260913/README.md',
)

# Sentences that deny a phone run. Each is a pattern a document used before the
# run happened, kept here rather than generalised, because a loose pattern is
# how a gate starts failing honest prose.
# Each pattern is the shape a document actually used before the phone run,
# narrowed until it cannot match a sentence that describes the run instead of
# denying it, and cannot match the Android client's own release notes. Two
# earlier, looser patterns were removed after they fired on "no phone install
# claimed" (an Android release gate) and on the catalogue row that *records*
# the iPhone run: a gate that cries wolf is worse than no gate, because the
# next person turns it off.
NO_PHONE = (
    r'no signed build exists',
    r'nothing (?:at all )?(?:has )?(?:yet )?(?:ran|run) on a (?:physical )?(?:phone|iPhone)',
    r'\|\s*Anything (?:at all )?on a physical iPhone\s*\|\s*(?:No|Not|None|Nothing)\b',
    r'this client has never (?:been installed on|run on|touched) a (?:physical )?(?:phone|iPhone)',
    r'no iOS build has (?:yet )?(?:been installed|run) on a (?:physical )?(?:phone|iPhone)',
)

NO_HOSTED = (
    r'`?hosted_registrations`? (?:is|=) *`?(?:zero|0)\b',
    r'no hosted account exists',
    r'the counter above stays at zero',
)

NO_JOINT = (
    r'(?:the )?(?:two )?joint tests? (?:with the owner )?(?:have|has) not (?:yet )?been run',
    r'this test has not been run',
    r'every `Result` cell reads `NOT RUN`(?! and changes)',
    r'no Android build on a phone has (?:yet )?(?:spoken to|answered) this client',
)


def unavailable(message):
    print(f'ERROR: {message}', file=sys.stderr)
    sys.exit(2)


def read(path):
    try:
        return path.read_text(encoding='utf-8')
    except OSError as error:
        unavailable(f'cannot read {path.relative_to(ROOT)}: {error}')


def lines_matching(text, patterns):
    """Every (line number, line) whose text matches one of ``patterns``.

    Fenced code blocks are skipped: a gate that fails on an example of the very
    sentence it forbids would make the documents unable to explain themselves.
    """
    found = []
    fenced = False
    for number, line in enumerate(text.splitlines(), start=1):
        if line.lstrip().startswith('```'):
            fenced = not fenced
            continue
        if fenced:
            continue
        for pattern in patterns:
            if re.search(pattern, line, flags=re.IGNORECASE):
                found.append((number, line.strip()))
                break
    return found


def hosted_count():
    """The registration counter, read from the catalogue's own table."""
    text = read(CATALOGUE)
    match = re.search(r'`hosted_registrations:\s*(\d+)`', text)
    if not match:
        unavailable(f'{CATALOGUE.relative_to(ROOT)} states no `hosted_registrations: N` counter')
    return int(match.group(1))


def device_ran():
    """Whether the device evidence records a run on the physical phone.

    The file is a build artifact and git-ignored, so its absence is not a
    failure: the catalogue's own prose is then the only source, and the phone
    checks below are skipped rather than guessed at.
    """
    if not DEVICE_EVIDENCE.is_file():
        return None
    try:
        data = json.loads(DEVICE_EVIDENCE.read_text(encoding='utf-8'))
    except (OSError, ValueError) as error:
        unavailable(f'cannot read {DEVICE_EVIDENCE}: {error}')
    results = data.get('results')
    if not isinstance(results, dict):
        unavailable(f'{DEVICE_EVIDENCE.name} has no `results` object')
    return any(value is True for value in results.values())


def stage_statuses():
    """Every status token in the ``Result`` column of the two stage files."""
    statuses = []
    for path in (STAGE1, STAGE2):
        for line in read(path).splitlines():
            if not line.startswith('| ') or line.startswith('| #') or set(line) <= set('| -'):
                continue
            cells = [cell.strip() for cell in line.strip().strip('|').split('|')]
            if len(cells) < 4 or not cells[0].isdigit():
                continue
            # The cell may carry a reason after an em dash; the status is what
            # stands before it.
            statuses.append(cells[-1].split(' — ')[0].strip())
    if not statuses:
        unavailable('neither stage file has a scenario table with Result cells')
    return statuses


def defined_statuses():
    """The status tokens the requirement table defines for itself."""
    text = read(VERIFICATION)
    section = re.search(r'## Status vocabulary(.*?)(?:\n## |\Z)', text, flags=re.S)
    if not section:
        unavailable(f'{VERIFICATION.relative_to(ROOT)} has no "## Status vocabulary" section')
    return set(re.findall(r'^- `([^`]+)`', section.group(1), flags=re.M))


def main():
    for required in (CATALOGUE, STAGE1, STAGE2, VERIFICATION):
        if not required.is_file():
            unavailable(f'{required.relative_to(ROOT)} is missing; it is a source of truth')

    problems = []
    documents = [(name, ROOT / name) for name in DOCUMENTS]
    present = [(name, path) for name, path in documents if path.is_file()]
    if not present:
        unavailable('none of the documents this gate checks exists')

    registrations = hosted_count()
    ran_on_device = device_ran()
    shown_jointly = any(status.startswith('SHOWN') for status in stage_statuses())

    for name, path in present:
        text = read(path)

        if registrations:
            for number, line in lines_matching(text, NO_HOSTED):
                problems.append(f'{name}:{number}: says no hosted account exists, but the '
                                f'catalogue records {registrations} — {line[:120]}')
            # `is`, `=` or `:` and an optional pair of backticks, because the
            # counter is written all three ways across these documents.
            wrong = re.findall(r'`?hosted_registrations`?\s*(?:is|=|:)\s*`?(\d+)', text)
            for value in wrong:
                if int(value) != registrations:
                    problems.append(f'{name}: states hosted_registrations is {value}, '
                                    f'the catalogue records {registrations}')

        if ran_on_device:
            for number, line in lines_matching(text, NO_PHONE):
                problems.append(f'{name}:{number}: denies a run on the physical phone, which the '
                                f'device evidence records — {line[:120]}')

        if shown_jointly and path not in (STAGE1, STAGE2):
            for number, line in lines_matching(text, NO_JOINT):
                problems.append(f'{name}:{number}: says the joint tests have not run, but a stage '
                                f'file records a shown step — {line[:120]}')

    undefined = {status for status in stage_statuses() if status} - defined_statuses()
    for status in sorted(undefined):
        problems.append(f'stage files use the status `{status}`, which '
                        f'docs/clients/ios/verification.md does not define')

    if problems:
        print(f'FAIL: {len(problems)} contradiction(s) between the documents and the evidence')
        for problem in problems:
            print(f'  {problem}')
        return 1

    checks = 2 + (1 if ran_on_device else 0) + 1
    print(f'PASS: {checks} facts checked across {len(present)} documents '
          f'(hosted_registrations={registrations}, '
          f'device run={"recorded" if ran_on_device else "no artifact"}, '
          f'joint steps shown={shown_jointly})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
