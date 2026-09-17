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

Comparing every document against one counter catches disagreement and nothing
else. On 2026-09-14 a third account was registered on the hosted alpha and
nobody touched the catalogue: every document still said two, none of them
contradicted the other, and this gate passed. It was extended that day because
of that shared stale counter. The counter is no longer a number somebody types
— the catalogue lists the registrations themselves and the number has to equal
how many are listed — so registering an account now means writing a record, and
a stale counter fails the build instead of passing it. The limit is worth
saying plainly: this gate runs offline and never asks the server anything, so
an account nobody wrote down anywhere is still invisible to it. What it removes
is the cheap version of the mistake — the number and the accounts behind it can
no longer drift apart in silence.

What it checks, and where each fact comes from:

1. **Hosted registrations.** How many accounts this branch created on the
   hosted alpha is how many are recorded in check 2 — not a number typed
   anywhere. No document may state a different one, or say that no hosted
   account exists.
2. **The registrations themselves.** ``artifacts.json`` carries one record per
   hosted account — its public id, the instant, the machine it was made from
   and one line on what it is for — and the counter must equal how many records
   there are. A record whose account id was never written down keeps ``null``
   and says why in a note: the gate counts it all the same, because inventing
   an id to satisfy a check would be the same lie in a new place.
3. **The physical phone.** If the device evidence records a run, no document may
   say that nothing has run on a phone or that no signed build exists.
4. **The joint tests.** The two stage files carry the authoritative ``Result``
   cells. If either records a shown step, no document may say that the joint
   tests have not been run; if neither does, no document may say they have.
5. **The status vocabulary.** Every status token used in a ``Result`` cell of
   the requirement table or the stage files must be defined in the vocabulary
   section of ``docs/clients/ios/verification.md``. A status nobody defined is
   how ``SHOWN`` quietly grew a second meaning.

Exit codes:
  0  ``PASS: N facts checked across M documents``
  1  at least one contradiction (each printed with its file and, for prose, the
     line; for a registration record, which record it is)
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
ARTIFACTS = EVIDENCE / 'artifacts.json'
STAGE1 = EVIDENCE / 'stage1-text.md'
STAGE2 = EVIDENCE / 'stage2-voice.md'
VERIFICATION = ROOT / 'docs/clients/ios/verification.md'
DEVICE_EVIDENCE = HERE / 'out/evidence/device-smoke-20260913/device-smoke-result.json'

# The machine-readable list of hosted registrations inside `artifacts.json`,
# and the shape one record has to have.
RECORDS_KEY = 'hosted_registration_records'
# `account` and `at` are checked by their own patterns; these two only have to
# say something.
RECORD_PROSE = ('machine', 'what')
ACCOUNT_ID = re.compile(r'^[0-9a-f]{64}$')
# A full ISO-8601 instant with an offset, or the bare date when that is all
# anybody wrote down — the two registrations of 2026-09-13 were recorded by
# date only, and a clock time invented to satisfy this pattern would be the
# same kind of untruth the gate is here to stop.
INSTANT = re.compile(r'^\d{4}-\d{2}-\d{2}'
                     r'(?:T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:\d{2}))?$')

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

# Number words a document may spell a count with. The reviewer showed that
# "Ninety-nine hosted accounts exist." passed the first version of this gate,
# which read only digits after the counter's own name; a count in prose is a
# count all the same.
NUMBER_WORDS = {w: i for i, w in enumerate(
    'zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen '
    'fifteen sixteen seventeen eighteen nineteen'.split())}
NUMBER_WORDS.update({w: 10 * (i + 2) for i, w in enumerate(
    'twenty thirty forty fifty sixty seventy eighty ninety'.split())})


def number_value(token):
    """`3`, `three` or `ninety-nine` as an integer; None when it is not a number."""
    token = token.lower()
    if token.isdigit():
        return int(token)
    if '-' in token:
        tens, _, ones = token.partition('-')
        if tens in NUMBER_WORDS and ones in NUMBER_WORDS:
            return NUMBER_WORDS[tens] + NUMBER_WORDS[ones]
        return None
    return NUMBER_WORDS.get(token)


# A count of hosted accounts stated in prose: "Two hosted accounts exist",
# "three accounts on the hosted alpha", "the branch created two accounts".
# The verb list is what keeps "two of the three registrations" and "the two
# registrations of 2026-09-13" from firing: those name a subset or a date, not
# the total, and neither is followed by exist/created/on the hosted.
PROSE_COUNT = re.compile(
    r'\b([A-Za-z]+(?:-[A-Za-z]+)?|\d+)\s+(?:hosted\s+)?(?:accounts?|registrations?)\s+'
    r'(?:exist|were created|have been created|on the hosted|created on the hosted)',
    flags=re.IGNORECASE)

NO_HOSTED = (
    r'`?hosted_registrations`? (?:is|=) *`?(?:zero|0)\b',
    r'no hosted account exists',
    r'the counter above stays at zero',
)

JOINT_COMPLETE = (
    # A negation in front — "neither joint test is complete" — is the opposite
    # claim and must not fire.
    r'(?<!neither )(?<!not )(?<!nor )(?<!never )joint tests? (?:with the owner )?(?:are|were|is|was|have been|has been) (?:complete|completed|fully run|finished|passed)',
    r'both joint tests (?:passed|completed|are done)',
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


def read_json(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError) as error:
        unavailable(f'cannot read {path.relative_to(ROOT)}: {error}')


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


def require_catalogue_counter():
    """The catalogue's table must still state ``hosted_registrations: N``.

    The number itself is no longer taken from here — the list of registrations
    below is — and the value written here is checked like any other document
    statement, because the catalogue is one of ``DOCUMENTS``. What stays fatal
    is the counter disappearing: the catalogue is where a reader looks first,
    and a catalogue that has stopped counting is not one.
    """
    if not re.search(r'`hosted_registrations:\s*\d+`', read(CATALOGUE)):
        unavailable(f'{CATALOGUE.relative_to(ROOT)} states no `hosted_registrations: N` counter')


def registration_records():
    """The hosted registrations themselves, with the counter written beside them.

    Both come out of ``artifacts.json``: the list is what exists, the counter is
    a claim about the list, and ``main`` makes the two agree. A missing, empty
    or malformed list is fatal rather than a contradiction — with nothing to
    count, the hosted checks below would be vacuous, which is exactly how a
    stale counter got through on 2026-09-14.
    """
    try:
        data = json.loads(read(ARTIFACTS))
    except ValueError as error:
        unavailable(f'cannot parse {ARTIFACTS.relative_to(ROOT)}: {error}')
    records = data.get(RECORDS_KEY)
    if not isinstance(records, list) or not records:
        unavailable(f'{ARTIFACTS.relative_to(ROOT)} carries no non-empty `{RECORDS_KEY}` '
                    'list; the hosted accounts are counted by listing them one by one')
    counter = data.get('hosted_registrations')
    if not isinstance(counter, int) or isinstance(counter, bool):
        unavailable(f'{ARTIFACTS.relative_to(ROOT)} states no whole-number '
                    '`hosted_registrations` counter')
    return records, counter


def registration_problems(records, counter):
    """Everything wrong inside the registration list itself.

    These are contradictions, not missing sources: the catalogue is readable and
    says two different things about the same accounts, or a record does not say
    enough to be one.
    """
    problems = []
    name = ARTIFACTS.relative_to(ROOT)
    if counter != len(records):
        problems.append(f'{name}: states hosted_registrations is {counter}, but lists '
                        f'{len(records)} registration(s) — an account is counted by '
                        f'recording it, not by raising the number')
    seen = {}
    for index, record in enumerate(records, start=1):
        where = f'{name}: registration {index}'
        if not isinstance(record, dict):
            problems.append(f'{where} is not an object')
            continue
        account = record.get('account')
        if account is None:
            if not str(record.get('note') or '').strip():
                problems.append(f'{where} records no account id and no `note` saying why; '
                                f'an id nobody wrote down must be told apart from one '
                                f'nobody bothered to copy')
        elif not isinstance(account, str) or not ACCOUNT_ID.match(account):
            problems.append(f'{where} has account `{account}`, which is neither null nor a '
                            f'64-digit lowercase hex account id')
        elif account in seen:
            problems.append(f'{where} repeats the account id of registration {seen[account]} '
                            f'— one account, one record')
        else:
            seen[account] = index
        if not isinstance(record.get('at'), str) or not INSTANT.match(record['at']):
            problems.append(f'{where} has at `{record.get("at")}`, which is not an ISO-8601 '
                            f'date or an instant with an offset')
        for field in RECORD_PROSE:
            if not isinstance(record.get(field), str) or not record[field].strip():
                problems.append(f'{where} does not say `{field}`')
    return problems


def device_recorded():
    """Whether the tracked catalogue records a run on the physical phone.

    The owner's reviewer found the first version of this check reading the raw
    device evidence, which is git-ignored build output: in a clean checkout the
    file is absent, the check quietly switched itself off, and a document
    denying any phone run passed. The source of truth is therefore the tracked
    ``artifacts.json``: a run happened if the catalogue carries a ``device``
    artifact with its digest. When the raw file is also present its SHA-256
    must match that record, so a catalogue that describes a file other than
    the one on disk fails instead of passing on a stale digest.
    """
    data = read_json(ARTIFACTS)
    records = [a for a in data.get('artifacts', [])
               if isinstance(a, dict) and (a.get('group') == 'device'
                                           or 'device-smoke' in str(a.get('path', '')))]
    if not records:
        return False
    if DEVICE_EVIDENCE.is_file():
        import hashlib
        digest = hashlib.sha256(DEVICE_EVIDENCE.read_bytes()).hexdigest()
        recorded = {r.get('sha256') for r in records if r.get('path', '').endswith('device-smoke-result.json')}
        if recorded and digest not in recorded:
            unavailable(f'{DEVICE_EVIDENCE.name} on disk has digest {digest[:12]}…, the catalogue '
                        f'records {sorted(recorded)[0][:12]}…; the evidence and its record disagree')
    return True


STATUS_TOKEN = re.compile(r'\b(NOT RUN|CLAIMED|FAILED|SHOWN(?:\s*\([^)]*\))?)')


def requirement_statuses():
    """Every status token in the ``Result`` cells of the requirement table.

    The owner's reviewer found that the first version of this gate never read
    this table at all, so a row could carry any word in its status cell. A
    ``Result`` cell may hold several tokens — a device result beside a joint
    one — and each is checked on its own; a row with none is reported too,
    because a row without a status is a claim without a verdict.
    """
    rows = []
    for number, line in enumerate(read(VERIFICATION).splitlines(), start=1):
        if not line.startswith('| ') or set(line) <= set('| -'):
            continue
        cells = [cell.strip() for cell in line.strip().strip('|').split('|')]
        if len(cells) < 4 or not cells[0].startswith('REQ-'):
            continue
        tokens = [t.strip() for t in STATUS_TOKEN.findall(cells[-1])]
        rows.append((number, cells[0], tokens, cells[-1]))
    if not rows:
        unavailable(f'{VERIFICATION.relative_to(ROOT)} has no requirement rows')
    return rows


def status_is_defined(token, defined):
    """Whether one token is a status the vocabulary section defines.

    ``SHOWN`` may carry a stand qualifier the vocabulary describes in prose —
    ``(phone, local stand)``, ``(phone, hosted)`` — so a qualified ``SHOWN``
    is defined when its qualifier names the phone; any other qualifier, and
    any other word, is a status nobody defined.
    """
    if token in defined:
        return True
    match = re.match(r'SHOWN\s*\((.*)\)$', token)
    return bool(match) and 'SHOWN' in defined and match.group(1).strip().startswith('phone')


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
    for required in (CATALOGUE, ARTIFACTS, STAGE1, STAGE2, VERIFICATION):
        if not required.is_file():
            unavailable(f'{required.relative_to(ROOT)} is missing; it is a source of truth')

    problems = []
    documents = [(name, ROOT / name) for name in DOCUMENTS]
    present = [(name, path) for name, path in documents if path.is_file()]
    if not present:
        unavailable('none of the documents this gate checks exists')

    require_catalogue_counter()
    records, counter = registration_records()
    problems.extend(registration_problems(records, counter))
    registrations = len(records)
    ran_on_device = device_recorded()
    shown_jointly = any(status.startswith('SHOWN') for status in stage_statuses())

    for name, path in present:
        text = read(path)

        if registrations:
            for number, line in lines_matching(text, NO_HOSTED):
                problems.append(f'{name}:{number}: says no hosted account exists, but the '
                                f'catalogue lists {registrations} — {line[:120]}')
            # `is`, `=` or `:` and an optional pair of backticks, because the
            # counter is written all three ways across these documents.
            wrong = re.findall(r'`?hosted_registrations`?\s*(?:is|=|:)\s*`?(\d+)', text)
            for value in wrong:
                if int(value) != registrations:
                    problems.append(f'{name}: states hosted_registrations is {value}, '
                                    f'the catalogue lists {registrations} registration(s)')
            for number, line in enumerate(text.splitlines(), start=1):
                for token in PROSE_COUNT.findall(line):
                    value = number_value(token)
                    if value is not None and value != registrations:
                        problems.append(f'{name}:{number}: says {token} hosted accounts, the catalogue '
                                        f'lists {registrations} — {line.strip()[:100]}')

        if ran_on_device:
            for number, line in lines_matching(text, NO_PHONE):
                problems.append(f'{name}:{number}: denies a run on the physical phone, which the '
                                f'device evidence records — {line[:120]}')

        if shown_jointly and path not in (STAGE1, STAGE2):
            for number, line in lines_matching(text, NO_JOINT):
                problems.append(f'{name}:{number}: says the joint tests have not run, but a stage '
                                f'file records a shown step — {line[:120]}')

    defined = defined_statuses()
    undefined = {status for status in stage_statuses() if status and not status_is_defined(status, defined)}
    for status in sorted(undefined):
        problems.append(f'stage files use the status `{status}`, which '
                        f'docs/clients/ios/verification.md does not define')

    # The requirement table itself: every Result cell carries only defined
    # statuses, and no phone status is claimed without a recorded device run.
    for number, req, tokens, cell in requirement_statuses():
        if not tokens:
            problems.append(f'docs/clients/ios/verification.md:{number}: {req} has no status in its '
                            f'Result cell — {cell[:80]}')
        for token in tokens:
            if not status_is_defined(token, defined):
                problems.append(f'docs/clients/ios/verification.md:{number}: {req} uses the status '
                                f'`{token}`, which the vocabulary does not define')
            if token.startswith('SHOWN') and 'phone' in token and not ran_on_device:
                problems.append(f'docs/clients/ios/verification.md:{number}: {req} claims `{token}` '
                                f'but the catalogue records no device artifact')

    # A joint test with any NOT RUN step left is not complete, whatever a
    # document says about it.
    if any(status.startswith('NOT RUN') for status in stage_statuses()):
        for name, path in present:
            if path in (STAGE1, STAGE2):
                continue
            for number, line in lines_matching(read(path), JOINT_COMPLETE):
                problems.append(f'{name}:{number}: says the joint tests are complete, but a stage '
                                f'file still has a NOT RUN step — {line[:120]}')

    if problems:
        print(f'FAIL: {len(problems)} contradiction(s) between the documents and the evidence')
        for problem in problems:
            print(f'  {problem}')
        return 1

    checks = 3 + (1 if ran_on_device else 0) + 3
    print(f'PASS: {checks} facts checked across {len(present)} documents '
          f'(hosted_registrations={registrations}, one record each, '
          f'device run={"recorded" if ran_on_device else "no artifact"}, '
          f'joint steps shown={shown_jointly})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
