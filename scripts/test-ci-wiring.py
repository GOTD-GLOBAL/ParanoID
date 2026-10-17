#!/usr/bin/env python3
"""Regression contract for the archival clean-v7/v8 CI harness (no runtime edits)."""
from pathlib import Path
import importlib.util
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Wiring(unittest.TestCase):
    def test_ios_shared_caption_dependencies_trigger_pr_and_main_checks(self):
        workflow = (ROOT / '.github/workflows/ios.yml').read_text()
        # Captions depend on Android sources; identity bridges depend on the
        # registrar/core. A producer-only change must not skip the consumer gate:
        # the iOS workflow runs for every change through ci.yml, unfiltered.
        self.assertEqual(triggers(workflow), ['workflow_call:'])
        self.assertIn('    uses: ./.github/workflows/ios.yml', ci_entry(self))
        self.assertIn('python3 clients/ios/test_ui_contract.py', workflow)
        self.assertNotIn('continue-on-error:', workflow)

    def test_single_entry_point_runs_every_component_on_every_change(self):
        ci = ci_entry(self)
        self.assertEqual(triggers(ci), ['pull_request:', 'push:', 'branches: [main]',
                                        'workflow_dispatch:'])
        self.assertNotIn('paths', ci.split('jobs:', 1)[0])
        self.assertNotIn('paths-ignore', ci)
        for name in ('docs', 'server', 'ios'):
            self.assertIn(f'  {name}:\n    uses: ./.github/workflows/{name}.yml\n', ci)
            workflow = (ROOT / f'.github/workflows/{name}.yml').read_text()
            # Reached only through ci.yml: no second, filtered trigger.
            self.assertEqual(triggers(workflow), ['workflow_call:'], name)
        workflows = ROOT / '.github/workflows'
        listed = sorted(path.name for pattern in ('*.yml', '*.yaml') for path in workflows.glob(pattern))
        self.assertEqual(listed, ['ci.yml', 'docs.yml', 'ios.yml', 'server.yml'])
        # Every job of the entry point except `gate` is a component that `gate` needs.
        self.assertEqual(job_ids(ci), ['docs', 'server', 'ios', 'gate'])

    def test_main_pushes_never_cancel_each_other(self):
        ci = ci_entry(self)
        # Only runs of one pull request share a group; a push to main or a manual
        # dispatch is grouped by its own run id, so no main commit loses its run.
        self.assertIn("format('ci-pr-{0}', github.event.pull_request.number)", ci)
        self.assertIn("|| format('ci-run-{0}', github.run_id) }}", ci)
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", ci)
        self.assertNotIn('github.ref }}', ci.split('concurrency:', 1)[1].split('jobs:', 1)[0])

    def test_no_workflow_masks_a_failure(self):
        for name in ('ci', 'docs', 'server', 'ios'):
            workflow = (ROOT / f'.github/workflows/{name}.yml').read_text()
            code = '\n'.join(line for line in workflow.splitlines()
                             if not line.lstrip().startswith('#'))
            self.assertNotIn('continue-on-error:', code, name)

    def test_required_gate_fails_unless_every_component_succeeded(self):
        ci = ci_entry(self)
        gate = ci.split('\n  gate:\n', 1)[1]
        self.assertIn('    name: gate\n', gate)
        self.assertIn('    if: always()\n', gate)
        self.assertIn('    needs: [docs, server, ios]\n', gate)
        self.assertIn('NEEDS_JSON: ${{ toJSON(needs) }}', gate)
        self.assertIn('expected = {"docs", "server", "ios"}', gate)
        self.assertIn('job["result"] != "success"', gate)
        self.assertNotIn('continue-on-error:', ci)

    def test_devnet_controller_and_integration_gate_ci(self):
        workflow = (ROOT / '.github/workflows/server.yml').read_text()
        # Registrar-only changes still run this job: server.yml is unfiltered.
        self.assertEqual(triggers(workflow), ['workflow_call:'])
        self.assertIn('  devnet-client:', workflow)
        job = workflow.split('  devnet-client:\n', 1)[1].split('  legacy-client-history:\n', 1)[0]
        for command in ('cargo +1.98.1 test --locked --manifest-path blockchain/solana/client/Cargo.toml',
                        'cargo +1.98.1 fetch --locked --manifest-path clients/core/Cargo.toml',
                        'python3 clients/android/test_devnet_integration.py',
                        'python3 clients/android/test_devnet_notices.py',
                        'python3 clients/android-devnet/check_controller.py'):
            self.assertIn(command, job)
            if command.startswith('python3 '):
                self.assertTrue((ROOT / command.split()[1]).is_file())
        self.assertLess(job.index('cargo +1.98.1 fetch --locked --manifest-path clients/core/Cargo.toml'),
                        job.index('python3 clients/android/test_devnet_notices.py'))
        self.assertNotIn('continue-on-error:', job)

    def test_message_time_gates_ci_and_android_build(self):
        workflow = (ROOT / '.github/workflows/server.yml').read_text()
        supported = workflow.split('  client-core-and-tls:\n', 1)[1].split('  legacy-client-history:\n', 1)[0]
        self.assertIn('python3 clients/android/test_message_time.py', supported)
        build = (ROOT / 'clients/android/build.sh').read_text()
        self.assertIn('python3 test_message_time.py', build)

    def test_android_call_rows_and_preserved_main_fixes_gate_in_ci(self):
        workflow = (ROOT / '.github/workflows/server.yml').read_text()
        supported = workflow.split('  client-core-and-tls:\n', 1)[1].split('  legacy-client-history:\n', 1)[0]
        for name in ('test_call_log.py', 'test_message_presentation.py',
                     'test_ui_contract.py', 'test_crash_exit.py'):
            self.assertIn('python3 clients/android/' + name, supported)

    def test_v2_backup_and_one_off_recovery_are_blocking_ci_gates(self):
        workflow = (ROOT / '.github/workflows/server.yml').read_text()
        package = job_runs('server', 'native-package')
        for name in ('deploy/test_reconcile_apk_cap_20260913.py',
                     'deploy/test_restore_active_after_rollback.py',
                     'scripts/check-v2-maintenance.py'):
            self.assertIn('python3 ' + name, package)
            self.assertTrue((ROOT / name).is_file())
        self.assertEqual(triggers(workflow), ['workflow_call:'])
        runner = (ROOT / 'scripts/check-v2-maintenance.py').read_text()
        for marker in ('self_service_v2=True', 'PARANOID_V2_OLD_RELEASE',
                       'PARANOID_TEST_PACKAGED', 'PARANOID_V2_RELEASE',
                       'test_v2_update.py', 'test_v2_maintenance_interrupts.py',
                       'check=True'):
            self.assertIn(marker, runner)

    def test_turn_offline_package_and_versioned_controller_gate(self):
        package = job_runs('server', 'native-package')
        for name in ('deploy/turn/test_package.py', 'deploy/turn/test_runtime.py',
                     'deploy/test_turn_environment.py', 'deploy/test_push_environment.py'):
            self.assertIn('python3 ' + name, package)
            self.assertTrue((ROOT / name).is_file())

    def test_server_uses_private_cluster_without_ci_tcp_bypass(self):
        job = workflow_yaml('server')['jobs']['postgres-http']
        server = job_runs('server', 'postgres-http') + '\n' + repr(job.get('env', {}))
        self.assertIn("python3 scripts/check-server.py", server)
        self.assertNotIn("PARANOID_CI_TEST_DATABASE", server)
        self.assertNotIn("PARANOID_TEST_DATABASE_URL", server)
        self.assertIn("postgresql-16", server)

    def test_server_suite_runs_in_proven_shards(self):
        checks = server_checks()
        job = workflow_yaml('server')['jobs']['postgres-http']
        self.assertIs(job['strategy']['fail-fast'], False)
        # The matrix is exactly the shard table, so a shard cannot be dropped.
        self.assertEqual(job['strategy']['matrix']['shard'], list(checks.SHARDS))
        self.assertEqual(job['env']['SHARD'], '${{ matrix.shard }}')
        runs = [step.get('run', '') for step in job['steps']]
        self.assertIn('python3 scripts/check-server.py --shard "$SHARD"', runs)
        self.assertNotIn('continue-on-error', job)
        # Format, lint and this wiring test run once, in their own job.
        lint = '\n'.join(step.get('run', '') for step in
                         workflow_yaml('server')['jobs']['server-lint']['steps'])
        for command in ('cargo +1.98.1 fmt --manifest-path server/Cargo.toml -- --check',
                        'cargo +1.98.1 clippy --locked --manifest-path server/Cargo.toml '
                        '--all-targets -- -D warnings',
                        'python3 scripts/test-ci-wiring.py'):
            self.assertIn(command, lint)

    def test_legacy_exact_failures_and_all_other_targets_gate(self):
        workflow = (ROOT / ".github/workflows/server.yml").read_text()
        self.assertIn("  legacy-client-history:\n", workflow)
        supported, legacy = workflow.split("  legacy-client-history:\n", 1)
        self.assertIn('for source in clients/core/tests/*.rs', supported)
        self.assertIn('if [[ "$name" != self_service ]]', supported)
        self.assertIn('--lib --bins "${tests[@]}"', supported)
        self.assertIn('--test self_service -- --exact "${legacy[@]}"', supported)
        names = (ROOT / 'scripts/ci-legacy-client-tests.txt').read_text().splitlines()
        self.assertEqual(len(names), 14)
        self.assertEqual(len(set(names)), 14)
        source = (ROOT / 'clients/core/tests/self_service.rs').read_text()
        for name in names:
            self.assertTrue(name.isidentifier())
            self.assertIn('fn ' + name + '()', source)
        self.assertNotIn('--skip', legacy)
        # The legacy job runs the whole target through the strict checker, which
        # itself runs `--test self_service` with no --skip and no exclusions.
        self.assertIn('run: python3 scripts/check-legacy-failures.py', legacy)
        # The exact command: the whole target, no filter, no --skip, no extra args.
        self.assertEqual(legacy_checker().COMMAND, [
            'cargo', '+1.98.1', 'test', '--locked',
            '--manifest-path', 'clients/core/Cargo.toml', '--test', 'self_service'])
        # Comments explain why no failure-masking attribute is allowed.
        self.assertNotIn('continue-on-error:', '\n'.join(
            line for line in workflow.splitlines() if not line.lstrip().startswith('#')))


class ServerShards(unittest.TestCase):
    """Selection logic of scripts/check-server.py, without cargo or PostgreSQL."""

    SHARDS = {'slow': ('t_slow',), 'rest': ()}
    INVENTORY = {'t_slow': 1, 't_a': 1, 't_b': 1}

    def setUp(self):
        from collections import Counter
        self.Counter = Counter
        self.checks = server_checks()
        self.inventory = Counter(self.INVENTORY)

    def problems(self, shard, selected, shards=None):
        shards = shards or self.SHARDS
        return self.checks.check_selection(self.inventory, self.Counter(selected), shard, shards)

    def test_real_shard_table_is_valid_and_disjoint(self):
        self.checks.validate_shards(self.checks.SHARDS)
        named = [name for names in self.checks.SHARDS.values() for name in names]
        self.assertEqual(len(named), len(set(named)))
        self.assertEqual(self.checks.SHARDS['rest'], ())

    def test_filters_select_exact_names_and_skip_them_in_rest(self):
        self.assertEqual(self.checks.filters(None, self.SHARDS), [])
        self.assertEqual(self.checks.filters('slow', self.SHARDS), ['--exact', 't_slow'])
        self.assertEqual(self.checks.filters('rest', self.SHARDS), ['--exact', '--skip', 't_slow'])

    def test_every_test_is_owned_exactly_once(self):
        owned = sum((self.checks.owned(self.inventory, shard, self.SHARDS)
                     for shard in self.SHARDS), self.Counter())
        self.assertEqual(owned, self.inventory)

    def test_exact_selection_passes(self):
        self.assertEqual(self.problems('slow', {'t_slow': 1}), [])
        self.assertEqual(self.problems('rest', {'t_a': 1, 't_b': 1}), [])

    def test_missing_and_extra_tests_fail(self):
        self.assertIn('would not run', '\n'.join(self.problems('rest', {'t_a': 1})))
        self.assertIn('tests it does not own',
                      '\n'.join(self.problems('rest', {'t_a': 1, 't_b': 1, 't_slow': 1})))

    def test_renamed_test_and_empty_selection_fail(self):
        shards = {'slow': ('t_renamed',), 'rest': ()}
        report = '\n'.join(self.problems('slow', {}, shards))
        self.assertIn('not a server test', report)
        self.assertIn('selects no test at all', report)

    def test_duplicate_or_second_catch_all_is_rejected(self):
        with self.assertRaises(SystemExit):
            self.checks.validate_shards({'a': ('x',), 'b': ('x',), 'rest': ()})
        with self.assertRaises(SystemExit):
            self.checks.validate_shards({'a': (), 'rest': ()})


def server_checks():
    spec = importlib.util.spec_from_file_location(
        'check_server', ROOT / 'scripts/check-server.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def job_runs(workflow, job):
    """Every `run:` script of one job, joined: the exact job, no neighbour."""
    steps = workflow_yaml(workflow)['jobs'][job]['steps']
    return '\n'.join(step.get('run', '') for step in steps)


def workflow_yaml(name):
    """A workflow parsed as YAML (needs PyYAML: apt python3-yaml)."""
    import yaml
    return yaml.safe_load((ROOT / f'.github/workflows/{name}.yml').read_text())


def legacy_checker():
    spec = importlib.util.spec_from_file_location(
        'check_legacy_failures', ROOT / 'scripts/check-legacy-failures.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def cargo_output(results):
    """Synthetic cargo test output for {name: status}."""
    lines = ['running %d tests' % len(results)]
    lines += ['test %s ... %s' % (name, status) for name, status in results.items()]
    counts = [sum(1 for s in results.values() if s == wanted) for wanted in ('ok', 'FAILED', 'ignored')]
    verdict = 'FAILED' if counts[1] else 'ok'
    lines.append('test result: %s. %d passed; %d failed; %d ignored; 0 measured; 0 filtered out; '
                 'finished in 0.01s' % (verdict, *counts))
    return '\n'.join(lines) + '\n'


class LegacyChecker(unittest.TestCase):
    """The legacy job is green only for exactly the documented historical failures."""

    def setUp(self):
        self.module = legacy_checker()
        self.expected = self.module.expected_names()
        self.assertEqual(len(self.expected), 14)
        self.baseline = {name: 'FAILED' for name in self.expected}
        self.baseline.update({'supported_case_%d' % i: 'ok' for i in range(10)})

    def verdict(self, results, exit_code=101):
        ok, report = self.module.evaluate(cargo_output(results), exit_code, self.expected)
        return ok, '\n'.join(report)

    def test_exact_historical_failures_pass(self):
        ok, report = self.verdict(self.baseline)
        self.assertTrue(ok, report)
        self.assertIn('Raw cargo exit: 101', report)
        for name in self.expected:
            self.assertIn('historical failure (retained, not fixed): ' + name, report)
        self.assertIn('RESULT: PASS (the same 14 listed tests fail; every other test passes)', report)

    def test_new_failure_fails(self):
        results = dict(self.baseline, supported_case_0='FAILED')
        ok, report = self.verdict(results)
        self.assertFalse(ok)
        self.assertIn('NEW failure outside the historical list: supported_case_0', report)

    def test_listed_test_that_now_passes_fails(self):
        name = sorted(self.expected)[0]
        ok, report = self.verdict(dict(self.baseline, **{name: 'ok'}))
        self.assertFalse(ok)
        self.assertIn('now passes', report)

    def test_missing_listed_test_fails(self):
        results = dict(self.baseline)
        results.pop(sorted(self.expected)[0])
        ok, report = self.verdict(results)
        self.assertFalse(ok)
        self.assertIn('did not run', report)

    def test_ignored_test_fails(self):
        ok, report = self.verdict(dict(self.baseline, supported_case_1='ignored'))
        self.assertFalse(ok)
        self.assertIn('ignored test: supported_case_1', report)

    def test_build_error_fails(self):
        ok, report = self.module.evaluate('error[E0425]: cannot find value\n', 101, self.expected)
        self.assertFalse(ok)
        self.assertIn('no test results parsed', '\n'.join(report))

    def test_exit_code_must_agree_with_results(self):
        ok, report = self.verdict(self.baseline, exit_code=0)
        self.assertFalse(ok)
        self.assertIn('cargo exited 0 although tests failed', report)

    def test_filtered_run_fails(self):
        output = cargo_output(self.baseline).replace('0 filtered out;', '3 filtered out;')
        ok, report = self.module.evaluate(output, 101, self.expected)
        self.assertFalse(ok)
        self.assertIn('the whole target must run unfiltered', '\n'.join(report))

    def test_summary_must_agree_with_lines(self):
        output = cargo_output(self.baseline).replace('10 passed;', '11 passed;')
        ok, report = self.module.evaluate(output, 101, self.expected)
        self.assertFalse(ok)
        self.assertIn('disagrees with parsed lines', '\n'.join(report))


def triggers(workflow):
    """Non-comment lines of a workflow's top-level `on:` block, stripped."""
    block = workflow.split('\non:\n', 1)[1].split('\npermissions:', 1)[0]
    return [line.strip() for line in block.splitlines()
            if line.strip() and not line.lstrip().startswith('#')]


def job_ids(workflow):
    """Top-level job ids of a workflow, in source order."""
    jobs = workflow.split('\njobs:\n', 1)[1]
    return [line[2:-1] for line in jobs.splitlines()
            if line.startswith('  ') and not line.startswith('   ')
            and line.endswith(':') and not line.lstrip().startswith('#')]


def ci_entry(case):
    path = ROOT / '.github/workflows/ci.yml'
    case.assertTrue(path.is_file())
    return path.read_text()


if __name__ == "__main__":
    unittest.main()
