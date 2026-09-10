"""TEST ONLY: bounded pure sampling, no I/O at import; no media verdicts.
Pass a bounded app callable. Prefer the test-only controller_view command adapter
rather than the legacy view (which also waits for the native text owner).
"""
import time
import math

ERRORS = frozenset(('owner_stopped', 'owner_deadline', 'internal'))
STATES = frozenset(('idle', 'starting', 'incoming', 'authorizing', 'outgoing', 'connecting', 'connected', 'ended'))
REASONS = frozenset(('', 'hangup', 'reject', 'cancel', 'busy', 'timeout', 'failed', 'unavailable'))


def enum(value, allowed):
    return value if type(value) is str and value in allowed else 'unknown'


def category(value):
    return value if type(value) is str and value in ERRORS else 'internal'


def error_category(error):
    if isinstance(error, TimeoutError):
        return 'owner_deadline'
    return category(getattr(error, 'observation_category', None))


def number(value):
    return value if type(value) is int and 0 <= value <= 2**63 - 1 else None


def safe_media_summary(raw):
    """Project already summarized actual SDK evidence, never derive a media verdict."""
    safe = {}
    for key in ('summary_available', 'still_current'):
        if type(raw.get(key)) is bool: safe[key] = raw[key]
    for key in ('generation', 'truncated_count'):
        if number(raw.get(key)) is not None: safe[key] = raw[key]
    if 'observation_error' in raw: safe['observation_error'] = category(raw['observation_error'])
    audio = raw.get('inbound_audio')
    if type(audio) is list:
        safe['truncated_count'] = safe.get('truncated_count', 0) + max(0, len(audio) - 8)
        safe['inbound_audio'] = []
        for source in audio[:8]:
            if type(source) is not dict:
                safe['observation_error'] = 'internal'
                continue
            item = {key: enum(source.get(key), allowed) for key, allowed in (
                ('codec', {'audio/opus'}), ('dtls_state', {'new', 'connecting', 'connected', 'closed', 'failed'}),
                ('selected_local_candidate_type', {'host', 'srflx', 'prflx', 'relay'}),
                ('selected_remote_candidate_type', {'host', 'srflx', 'prflx', 'relay'}))}
            if number(source.get('total_samples_received')) is not None:
                item['total_samples_received'] = source['total_samples_received']
            energy = source.get('total_audio_energy')
            if type(energy) in (int, float) and 0 <= energy <= 1e308 and math.isfinite(energy):
                item['total_audio_energy'] = energy
            safe['inbound_audio'].append(item)
    return safe


def safe_sdk(raw):
    safe = {}
    for key in ('media_present', 'engine_closed', 'local_description_published',
                'relay_publication_scheduled', 'observed_on_media_owner', 'still_current'):
        if type(raw.get(key)) is bool: safe[key] = raw[key]
    for key in ('generation', 'local_candidate_count'):
        if number(raw.get(key)) is not None: safe[key] = raw[key]
    for key, allowed in (
        ('ice_gathering_state', {'new', 'gathering', 'complete'}),
        ('ice_connection_state', {'new', 'checking', 'connected', 'completed', 'failed', 'disconnected', 'closed'}),
        ('peer_connection_state', {'new', 'connecting', 'connected', 'disconnected', 'failed', 'closed'})):
        if key in raw: safe[key] = enum(raw[key], allowed)
    counts = raw.get('local_candidate_types')
    if type(counts) is dict:
        safe['local_candidate_types'] = {k: counts[k] for k in ('host', 'srflx', 'prflx', 'relay', 'unknown')
                                         if number(counts.get(k)) is not None}
    return safe


class Sampler:
    def __init__(self, capacity=256, clock=time.monotonic):
        if type(capacity) is not int or not 2 <= capacity <= 4096:
            raise ValueError('sample capacity bound')
        self.timeline = []
        self.capacity = capacity
        self.truncated_count = 0
        self.result = 'OBSERVING'
        self.observation_incomplete = False
        self.controller_error = None
        self._clock = clock
        self._start = clock()
        self._sequence = 0
        self._censored = False

    def _controller(self, app):
        try:
            response = app()
            view = response['call']
            sample: dict = {'call_state': enum(view.get('state'), STATES),
                            'call_reason': enum(view.get('reason'), REASONS)}
            for key in ('media_active', 'auth_online_observed'):
                if type(view.get(key)) is bool: sample[key] = view[key]
            for key in ('media_present',):
                if type(response.get(key)) is bool: sample[key] = response[key]
            for key in ('active_recordings', 'audio_mode', 'media_closing'):
                if number(response.get(key)) is not None: sample[key] = response[key]
            if 'cleanup_observation_error' in response:
                sample['cleanup_observation_error'] = category(response['cleanup_observation_error'])
                self.observation_incomplete = True
            raw_budgets = response.get('budgets')
            if type(raw_budgets) is dict:
                sample['budgets'] = {key: raw_budgets[key] for key in (
                    'generation', 'sample_mono_ms', 'setup_remaining_ms', 'disconnect_remaining_ms',
                    'silence_remaining_ms', 'max_call_remaining_ms') if number(raw_budgets.get(key)) is not None}
                if type(raw_budgets.get('available')) is bool:
                    sample['budgets']['available'] = raw_budgets['available']
            if number(view.get('generation')) is not None: sample['generation'] = view['generation']
        except Exception as error:
            self.controller_error = error_category(error)
            self.observation_incomplete = True
            self.result = 'OBSERVATION_INCOMPLETE'
            return None
        self._sequence += 1
        sample.update(sequence=self._sequence, seconds=max(0, self._clock() - self._start))
        if len(self.timeline) == self.capacity:
            del self.timeline[0]
            self.truncated_count += 1
        self.timeline.append(sample)  # MUST precede any media query.
        if sample['call_state'] == 'ended': self.result = 'OBSERVED_ENDED'
        return sample

    def step(self, app):
        if self._censored or self.result == 'OBSERVED_ENDED': return None
        sample = self._controller(app)
        if sample is None or self.result == 'OBSERVED_ENDED': return sample
        error_code = None
        try:
            raw = app('media_settings')
            if 'observation_error' in raw: error_code = category(raw['observation_error'])
            else: sample['sdk'] = safe_sdk(raw)
        except Exception as error:
            error_code = error_category(error)
        if error_code is not None:
            sample['observation_error'] = error_code
            self.observation_incomplete = True
            self.result = 'OBSERVATION_INCOMPLETE'
            self._controller(app)  # One bounded fresh read, not a fabricated terminal.
        return sample

    def censor(self):
        self._censored = True
        if self.result != 'OBSERVED_ENDED':
            self.result = 'OBSERVATION_INCOMPLETE' if self.observation_incomplete else 'CENSORED_NO_TERMINAL'
