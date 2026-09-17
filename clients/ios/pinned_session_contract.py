"""Finite lexical ATS-off regression gate (REQ-CLIENT-001, RFC-0021/ADR-0014).

Scope is App/ParanoID and ParanoidKit/Sources/ParanoidKit, recursively, including
inactive #if branches. The caller supplies that inventory. Host probes, tests,
SwiftPM manifests, generated/binary dependencies and other networking APIs are
not covered. This is NOT Swift parsing, name resolution, data-flow analysis or
proof of TLS behavior. Runtime pin/redirect/configuration tests remain necessary.

Policy: exactly one reviewed constructor expression in each of three files;
reviewed factory/delegate wiring; no other URLSession value references, aliases,
literal URLSession.self metatypes, subclasses, explicit .init or .shared.
Computed type(of:) metatypes, generic T.init and reflection are not excluded.
Simple immediately inferred
initializers/shared values in URLSession annotations/returns are also rejected.
Arbitrary inferred expressions, shadowing, macros, reflection, imported aliases
and computed factories need Swift-aware review; do not describe this as semantic
proof. New spellings/sites fail review rather than extending the allowlist by
filename alone. Comments (including nested ones) and ordinary/raw/multiline
strings cannot satisfy a constructor. Interpolations mentioning URLSession are
conservatively refused, not parsed as Swift expressions.
"""
import re

BASE = 'ParanoidKit/Sources/ParanoidKit/'
PINNED = BASE + 'Tls/PinnedSessionDelegate.swift'
REALTIME = BASE + 'Net/RealtimeTransport.swift'
RELAY = BASE + 'Voice/VoiceRelayTransport.swift'
APPROVED = {
    PINNED: 'URLSession(configuration: Self.configuration(), delegate: self, delegateQueue: delegateQueue)',
    REALTIME: 'URLSession(configuration: configuration(lane: lane), delegate: pinned, delegateQueue: nil)',
    RELAY: 'URLSession(configuration: Self.configuration(), delegate: pinned, delegateQueue: nil)',
}
WIRING = {
    PINNED: (
        'public final class PinnedSessionDelegate: NSObject, URLSessionDelegate, Sendable {',
        'public func makeSession(delegateQueue: OperationQueue? = nil) -> URLSession {'
        + APPROVED[PINNED] + '}',
    ),
    REALTIME: (
        'public let pinned: PinnedSessionDelegate',
        'self.pinned = PinnedSessionDelegate(evaluator: evaluator)',
        'let configuration = PinnedSessionDelegate.configuration()',
        'private static func makeSession(pinned: PinnedSessionDelegate, lane: Lane) -> URLSession {'
        + APPROVED[REALTIME] + '}',
    ),
    RELAY: (
        'public let pinned: PinnedSessionDelegate',
        'self.pinned = PinnedSessionDelegate(evaluator: evaluator)',
        'let configuration = PinnedSessionDelegate.configuration()',
        'public func get(authorization: String) async throws -> [UInt8] {'
        'let request = try makeRequest(authorization: authorization) let session ='
        + APPROVED[RELAY],
    ),
}

# Not a Swift lexer: preserve token boundaries; treat non-code as opaque.
TOKEN = re.compile(r'`[^`]+`|[A-Za-z_][A-Za-z_0-9]*|->|\S')
STRING_START = re.compile(r'(\#*)("""|")')


def swift_tokens(source, path):
    tokens = []
    i = 0
    while i < len(source):
        if source[i].isspace():
            i += 1
            continue
        if source.startswith('//', i):
            end = source.find('\n', i)
            i = len(source) if end < 0 else end + 1
            continue
        if source.startswith('/*', i):
            depth = 1
            i += 2
            while depth and i < len(source):
                if source.startswith('/*', i):
                    depth += 1
                    i += 2
                elif source.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            if depth:
                raise AssertionError(f'{path}: unterminated comment in pinned constructor scan')
            continue
        string = STRING_START.match(source, i)
        if string:
            hashes, quote = string.groups()
            start = i
            i = string.end()
            end_mark = quote + hashes
            escape = '\\' + hashes
            while i < len(source):
                if source.startswith(end_mark, i):
                    i += len(end_mark)
                    break
                if source.startswith(escape, i):
                    i += len(escape) + 1
                else:
                    i += 1
            else:
                raise AssertionError(f'{path}: unterminated string in pinned constructor scan')
            literal = source[start:i]
            if escape + '(' in literal and re.search(r'\bURLSession\b', literal):
                raise AssertionError(f'{path}: URLSession in interpolation needs explicit review')
            tokens.append('<string>')
            continue
        match = TOKEN.match(source, i)
        if match is None:
            raise AssertionError(f'{path}: unsupported token in pinned constructor scan')
        tokens.append(match.group().strip('`'))
        i = match.end()
    return tokens


def occurrences(tokens, pattern):
    return [i for i in range(len(tokens) - len(pattern) + 1)
            if tokens[i:i + len(pattern)] == pattern]


def assert_pinned_session_construction(sources):
    missing = set(APPROVED) - set(sources)
    if missing:
        raise AssertionError(f'missing approved pinned constructor source: {sorted(missing)}')
    for path, source in sources.items():
        tokens = swift_tokens(source, path)
        if path in APPROVED:
            for required in WIRING[path]:
                if len(occurrences(tokens, swift_tokens(required, path))) != 1:
                    raise AssertionError(f'{path}: expected one reviewed pinned wiring: {required}')
            expected = swift_tokens(APPROVED[path], path)
            sites = occurrences(tokens, expected)
            if len(sites) != 1:
                raise AssertionError(f'{path}: expected exactly one approved pinned constructor')
            # Remove the sole approved expression; every remaining URLSession
            # must be a permitted type reference, never a constructor or value.
            start = sites[0]
            tokens[start:start + len(expected)] = ['<approved-constructor>']
        # Foundation qualification is not an escape; other qualification fails
        # closed as an unreviewed reference rather than guessing its meaning.
        i = 0
        while i < len(tokens):
            if tokens[i:i + 3] == ['Foundation', '.', 'URLSession']:
                del tokens[i:i + 2]
            i += 1
        for i, token in enumerate(tokens):
            if token == 'URLSessionConfiguration' and tokens[i + 1:i + 3] == ['.', 'default']:
                raise AssertionError(f'{path}: URLSessionConfiguration.default is forbidden')
            if token != 'URLSession':
                continue
            before = tokens[i - 1] if i else ''
            after = tokens[i + 1:]
            if after[:2] in (['.', 'AuthChallengeDisposition'], ['.', 'ResponseDisposition']):
                # Only the two enum types used by delegate callbacks.
                continue
            if before not in (':', '->') or after[:1] in (['('], ['.']):
                raise AssertionError(f'{path}: unapproved URLSession constructor/value/alias')
            # A class inheritance clause is not an ordinary type annotation.
            if i >= 3 and tokens[i - 3] == 'class':
                raise AssertionError(f'{path}: URLSession subclass is not approved')
            if after[:1] in (['?'], ['!']):
                after = after[1:]
            if after[:1] in (['='], ['{']):
                expression = after[1:]
                if expression[:1] == ['return']:
                    expression = expression[1:]
                if expression[:2] in (['.', 'init'], ['.', 'shared']):
                    raise AssertionError(f'{path}: inferred URLSession constructor/shared value')
