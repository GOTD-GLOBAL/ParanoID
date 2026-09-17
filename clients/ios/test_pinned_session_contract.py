#!/usr/bin/env python3
"""Offline mutants run the actual Info.plist/constructor gate on source copies.

No Swift file is edited, compiled or executed. Run this file directly for the
mutation suite; each mutant exercises the existing UiContract gate entry point.
"""
import unittest

import test_ui_contract as ui
from pinned_session_contract import APPROVED, BASE


class PinnedSessionMutations(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sources = ui.swift_sources(ui.APP, ui.KIT)

    def check_sources(self, sources):
        case = ui.UiContract('test_info_plist_declares_camera_and_microphone_and_no_delivery_path')
        case.sources = sources
        case.test_info_plist_declares_camera_and_microphone_and_no_delivery_path()

    def reject_added(self, addition, path=ui.MODEL):
        sources = dict(self.sources)
        sources[path] = sources.get(path, '') + '\n' + addition + '\n'
        with self.assertRaisesRegex(AssertionError, 'URLSession|pinned|constructor'):
            self.check_sources(sources)

    def test_current_production_sources_pass(self):
        self.check_sources(self.sources)

    def test_configuration_variable_bypass_is_rejected_in_every_production_file(self):
        for path in self.sources:
            with self.subTest(path=path):
                self.reject_added('let cfg=URLSessionConfiguration.ephemeral; '
                                  'let session=URLSession(configuration: cfg)', path)

    def test_new_nested_production_file_is_not_allowlisted(self):
        for path in ('App/ParanoID/New/Nested.swift', BASE + 'New/Nested.swift'):
            with self.subTest(path=path):
                self.reject_added('let session = URLSession()', path)

    def test_alternate_construction_and_alias_forms_are_rejected(self):
        for code in (
            'let session = URLSession()',
            'let session = URLSession(configuration: .ephemeral)',
            'let session = URLSession(configuration: .default)',
            'let session = URLSession(configuration: cfg, delegate: nil, delegateQueue: nil)',
            'let session = URLSession(configuration: cfg, delegate: other, delegateQueue: nil)',
            'let session = URLSession /* split */ ( configuration: cfg )',
            'let session = Foundation.URLSession(configuration: cfg)',
            'let session = Foundation . URLSession . init (configuration: cfg)',
            'let session = URLSession\n.\nshared',
            'let session = Foundation.URLSession.shared',
            'typealias Session = URLSession; let session = Session(configuration: cfg)',
            'typealias Session = Foundation.URLSession; let session = Session()',
            'typealias Session = URLSession; typealias Other = Session; let s = Other()',
            'let factory = URLSession.init; let session = factory(cfg)',
            'let factory = URLSession.self; let session = factory.init(configuration: cfg)',
            'let factory = (URLSession).init; let session = factory(configuration: cfg)',
            'let factory: URLSession.Type = URLSession.self',
            'class Unpinned: URLSession {}',
            'let session: URLSession = .init(configuration: cfg)',
            'let session: Foundation.URLSession? = .shared',
            'func make() -> URLSession { .init(configuration: cfg) }',
            'func make() -> URLSession { return .shared }',
            'let session = "\\(URLSession(configuration: cfg))"',
            'let cfg = URLSessionConfiguration /* split */ . default',
        ):
            with self.subTest(code=code):
                self.reject_added(code)

    def test_each_approved_constructor_is_required_and_not_duplicable(self):
        for path, constructor in APPROVED.items():
            with self.subTest(path=path, mutation='duplicate'):
                self.reject_added(constructor, path)
            with self.subTest(path=path, mutation='missing file'):
                sources = dict(self.sources)
                del sources[path]
                with self.assertRaisesRegex(AssertionError, 'pinned|constructor'):
                    self.check_sources(sources)

    def test_correct_delegate_constructor_in_wrong_file_is_rejected(self):
        for constructor in APPROVED.values():
            with self.subTest(constructor=constructor):
                self.reject_added(constructor)

    def test_approved_site_cannot_lose_or_replace_delegate_or_configuration(self):
        for path in APPROVED:
            for old, new in (
                ('delegate: self', 'delegate: nil'),
                ('delegate: pinned', 'delegate: nil'),
                ('delegate: self', 'delegate: other'),
                ('delegate: pinned', 'delegate: other'),
                ('delegate: pinned, ', ''),
                ('delegate: self, ', ''),
                ('configuration: Self.configuration()', 'configuration: cfg'),
                ('configuration: configuration(lane: lane)', 'configuration: cfg'),
            ):
                if old not in self.sources[path]:
                    continue
                with self.subTest(path=path, old=old, new=new):
                    sources = dict(self.sources)
                    sources[path] = sources[path].replace(old, new, 1)
                    with self.assertRaisesRegex(AssertionError, 'pinned|constructor'):
                        self.check_sources(sources)

    def test_delegate_type_or_initialization_cannot_be_replaced(self):
        for path in (BASE + 'Net/RealtimeTransport.swift', BASE + 'Voice/VoiceRelayTransport.swift'):
            for old, new in (
                ('public let pinned: PinnedSessionDelegate', 'public let pinned: OtherDelegate'),
                ('self.pinned = PinnedSessionDelegate(evaluator: evaluator)', 'self.pinned = OtherDelegate()'),
            ):
                with self.subTest(path=path, old=old):
                    sources = dict(self.sources)
                    self.assertIn(old, sources[path])
                    sources[path] = sources[path].replace(old, new, 1)
                    with self.assertRaisesRegex(AssertionError, 'pinned|constructor'):
                        self.check_sources(sources)

    def test_comments_cannot_stand_in_for_missing_constructor(self):
        path = BASE + 'Tls/PinnedSessionDelegate.swift'
        constructor = APPROVED[path]
        for replacement in ('// ' + constructor, '/* outer /* inner */ ' + constructor + ' */',
                            '"' + constructor + '"'):
            with self.subTest(replacement=replacement):
                sources = dict(self.sources)
                self.assertIn(constructor, sources[path])
                sources[path] = sources[path].replace(constructor, replacement, 1)
                with self.assertRaisesRegex(AssertionError, 'pinned|constructor'):
                    self.check_sources(sources)

    def test_comments_strings_and_type_references_are_not_constructors(self):
        sources = dict(self.sources)
        sources[ui.MODEL] += r'''
// URLSession.shared, URLSession(configuration: cfg)
/* nested /* URLSession() */ URLSession.init */
let documentation = "URLSession.shared or URLSession(configuration: cfg)"
let raw = #"URLSession(configuration: cfg)"#
let multiline = """URLSession()
URLSession.shared"""
func observe(_ session: URLSession, disposition: URLSession.AuthChallengeDisposition) {}
let existing: URLSession?
'''
        self.check_sources(sources)

    def test_approved_constructors_accept_whitespace_and_nested_comments(self):
        sources = dict(self.sources)
        for path in APPROVED:
            sources[path] = sources[path].replace('URLSession(configuration:',
                'URLSession /* outer /* inner */ end */ \n ( configuration :')
        self.check_sources(sources)


if __name__ == '__main__':
    unittest.main()
