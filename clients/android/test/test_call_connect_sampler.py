"""Anonymous control-flow only: no SDK/media/network fixture imports."""
import ast
import os
from pathlib import Path
import unittest


def baseline_step(app, timeline):
    # Execute ONLY the original two sampling statements, never import its harness.
    tree = ast.parse(Path(os.environ['BASELINE_DRIVER']).read_text())
    attempt = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'attempt')
    loop = next(n for n in attempt.body if isinstance(n, ast.While))
    selected = ast.Module(body=loop.body[:4], type_ignores=[])
    # line 76 has three statements; line 77 is the fourth (append).
    from types import SimpleNamespace
    scope = {'ui': SimpleNamespace(app=app), 'case': {'timeline': timeline},
             'time': SimpleNamespace(monotonic=lambda: 1), 'start': 0}
    exec(compile(selected, '<baseline-sampling-only>', 'exec'), scope)


class SamplerTests(unittest.TestCase):
    def test_ended_survives_observer_failure(self):
        timeline = []
        queries = []
        def app(command='view'):
            queries.append(command)
            if command == 'media_settings':
                raise RuntimeError('anonymous stopped observer')
            return {'call': {'state': 'ended', 'reason': 'failed', 'generation': 2}}
        if os.environ.get('SAMPLER_BASELINE') == '1':
            try:
                baseline_step(app, timeline)
            except RuntimeError:
                pass
        else:
            from call_connect_sampler import Sampler
            sampler = Sampler()
            sampler.step(app)
            timeline = sampler.timeline
        self.assertTrue(timeline, 'terminal controller evidence was lost before append')
        self.assertEqual(timeline[0]['call_state'], 'ended')
        self.assertEqual(timeline[0]['call_reason'], 'failed')
        self.assertEqual(queries, ['view'])

    def test_connecting_error_categories_and_followup(self):
        from call_connect_sampler import Sampler
        for category in ('owner_stopped', 'owner_deadline', 'internal', 'private-unrecognized'):
            with self.subTest(category=category):
                s = Sampler()
                states = iter(['connecting', 'connecting', 'ended'])
                def app(command='view'):
                    if command == 'media_settings':
                        error = RuntimeError('PRIVATE_PAYLOAD must not survive')
                        error.observation_category = category
                        raise error
                    return {'call': {'state': next(states), 'reason': 'failed', 'generation': 2}}
                s.step(app)
                self.assertEqual(s.result, 'OBSERVATION_INCOMPLETE')
                self.assertEqual(len(s.timeline), 2)
                self.assertEqual(s.timeline[0]['observation_error'], category if category != 'private-unrecognized' else 'internal')
                self.assertNotIn('PRIVATE_PAYLOAD', repr(vars(s)))
                s.step(app)
                self.assertEqual(s.result, 'OBSERVED_ENDED')
                self.assertEqual(s.timeline[0]['call_state'], 'connecting')
                self.assertEqual(s.timeline[-1]['call_state'], 'ended')

    def test_immediate_followup_terminal(self):
        from call_connect_sampler import Sampler
        s = Sampler()
        states = iter(['connecting', 'ended'])
        def app(command='view'):
            if command == 'media_settings':
                return {'observation_error': 'owner_stopped'}
            return {'call': {'state': next(states), 'reason': 'timeout'}}
        s.step(app)
        self.assertEqual(s.result, 'OBSERVED_ENDED')
        self.assertEqual(s.timeline[0]['observation_error'], 'owner_stopped')
        self.assertEqual(s.timeline[-1]['call_reason'], 'timeout')

    def test_censored_never_infers_terminal(self):
        from call_connect_sampler import Sampler
        s = Sampler()
        def app(command='view'):
            if command == 'media_settings':
                raise TimeoutError('PRIVATE_PAYLOAD')
            return {'call': {'state': 'connecting', 'reason': ''}}
        s.step(app)
        s.censor()
        self.assertEqual(s.result, 'OBSERVATION_INCOMPLETE')
        self.assertFalse(any(x['call_state'] == 'ended' for x in s.timeline))

    def test_followup_view_error_preserves_prior(self):
        from call_connect_sampler import Sampler
        s = Sampler()
        count = 0
        def app(command='view'):
            nonlocal count
            count += 1
            if count > 1:
                raise RuntimeError('PRIVATE_PAYLOAD')
            return {'call': {'state': 'connecting', 'reason': ''}}
        s.step(app)
        self.assertEqual(s.timeline[0]['call_state'], 'connecting')
        self.assertEqual(s.result, 'OBSERVATION_INCOMPLETE')
        self.assertNotIn('PRIVATE_PAYLOAD', repr(vars(s)))

    def test_bounded_sanitized_healthy_samples(self):
        from call_connect_sampler import Sampler
        s = Sampler(capacity=2)
        sdk = {'media_present': True, 'ice_connection_state': 'checking',
               'ice_gathering_state': 'gathering', 'local_description_published': False,
               'generation': 2, 'local_candidate_count': 1, 'local_candidate_types': {'relay': 1, 'PRIVATE_PAYLOAD': 4},
               'address': 'PRIVATE_PAYLOAD', 'sdp': 'PRIVATE_PAYLOAD'}
        def app(command='view'):
            if command == 'media_settings': return sdk
            return {'call': {'state': 'connecting', 'reason': '', 'generation': 2,
                             'account': 'PRIVATE_PAYLOAD'}, 'text': 'PRIVATE_PAYLOAD'}
        for _ in range(5): s.step(app)
        self.assertEqual(len(s.timeline), 2)
        self.assertEqual(s.truncated_count, 3)
        self.assertEqual(s.timeline[-1]['sdk']['ice_connection_state'], 'checking')
        self.assertEqual(s.timeline[-1]['sdk']['local_candidate_types'], {'relay': 1})
        self.assertNotIn('PRIVATE_PAYLOAD', repr(vars(s)))
        s.censor()
        self.assertEqual(s.result, 'CENSORED_NO_TERMINAL')

    def test_unknown_values_and_error_field_not_filtered(self):
        from call_connect_sampler import Sampler
        s = Sampler()
        def app(command='view'):
            if command == 'media_settings': return {'observation_error': 'PRIVATE_PAYLOAD'}
            return {'call': {'state': 'PRIVATE_PAYLOAD', 'reason': 'PRIVATE_PAYLOAD'}}
        s.step(app)
        self.assertNotIn('PRIVATE_PAYLOAD', repr(vars(s)))
        self.assertEqual(s.timeline[0]['observation_error'], 'internal')
        self.assertEqual(s.timeline[0]['call_state'], 'unknown')

    def test_controller_budgets_preserved_without_payload(self):
        from call_connect_sampler import Sampler
        s = Sampler(clock=lambda: 12)
        s.step(lambda command='view': {'call': {'state': 'ended', 'reason': 'timeout', 'generation': 2},
              'budgets': {'available': True, 'generation': 2, 'setup_remaining_ms': 0,
                          'sample_mono_ms': 12, 'PRIVATE_PAYLOAD': 'PRIVATE_PAYLOAD'}})
        self.assertEqual(s.timeline[0].get('budgets', {}).get('setup_remaining_ms'), 0)
        self.assertNotIn('PRIVATE_PAYLOAD', repr(vars(s)))

    def test_no_queries_after_censor(self):
        from call_connect_sampler import Sampler
        s = Sampler()
        s.censor()
        def forbidden(command='view'):
            self.fail('after-censored observation must not run')
        s.step(forbidden)
        self.assertEqual(s.timeline, [])

    def test_controller_retains_cleanup_and_authority_without_payload(self):
        from call_connect_sampler import Sampler
        s = Sampler()
        s.step(lambda command='view': {'call': {'state': 'ended', 'reason': 'failed',
              'media_active': False, 'auth_online_observed': True, 'account': 'PRIVATE_PAYLOAD'},
              'media_present': False, 'media_closing': 1, 'active_recordings': 0, 'audio_mode': 3,
              'private': 'PRIVATE_PAYLOAD'})
        sample = s.timeline[0]
        self.assertIs(sample.get('media_active'), False)
        self.assertIs(sample.get('auth_online_observed'), True)
        self.assertIs(sample.get('media_present'), False)
        self.assertEqual(sample.get('media_closing'), 1)
        self.assertEqual(sample.get('active_recordings'), 0)
        self.assertEqual(sample.get('audio_mode'), 3)
        self.assertNotIn('PRIVATE_PAYLOAD', repr(vars(s)))

    def test_safe_media_summary_allowlist_and_numeric_validation(self):
        from call_connect_sampler import safe_media_summary
        raw = {'summary_available': True, 'still_current': True, 'generation': 2,
               'inbound_audio': [{'codec': 'audio/opus', 'dtls_state': 'connected',
                   'selected_local_candidate_type': 'relay', 'selected_remote_candidate_type': 'relay',
                   'total_samples_received': 48000, 'total_audio_energy': 0.125,
                   'address': 'PRIVATE_PAYLOAD', 'id': 'PRIVATE_PAYLOAD'},
                   {'codec': 'PRIVATE_PAYLOAD', 'dtls_state': 'PRIVATE_PAYLOAD',
                    'total_samples_received': True, 'total_audio_energy': float('nan')}],
               'stats': 'PRIVATE_PAYLOAD'}
        value = safe_media_summary(raw)
        self.assertEqual(value['inbound_audio'][0]['total_samples_received'], 48000)
        self.assertEqual(value['inbound_audio'][0]['total_audio_energy'], 0.125)
        self.assertEqual(value['inbound_audio'][1]['codec'], 'unknown')
        self.assertNotIn('total_samples_received', value['inbound_audio'][1])
        self.assertNotIn('total_audio_energy', value['inbound_audio'][1])
        self.assertNotIn('PRIVATE_PAYLOAD', repr(value))

    def test_safe_media_summary_keeps_observer_error_and_truncation(self):
        from call_connect_sampler import safe_media_summary
        result = safe_media_summary({'observation_error': 'owner_deadline', 'truncated_count': 2,
                                     'inbound_audio': [{}] * 10})
        self.assertEqual(result['observation_error'], 'owner_deadline')
        self.assertEqual(result['truncated_count'], 4)
        self.assertEqual(len(result['inbound_audio']), 8)


if __name__ == '__main__':
    unittest.main()
