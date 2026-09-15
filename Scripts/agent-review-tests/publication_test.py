import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / '.github/agent-review' / f'{name}.py')
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


publisher = module('publish')
evidence = module('evidence')


def failure(status, message='rejected'):
    return publisher.APIError(subprocess.CompletedProcess([], 1, json.dumps({'message': message}), f'HTTP {status}'))


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.env = dict(REVIEW_OUT=self.temp.name, REVIEW_PENDING=str(self.directory / 'pending.json'),
                        GITHUB_REPOSITORY='owner/repo', PR_NUMBER='1', HEAD_SHA='a' * 40,
                        REVIEW_MARKER='<!-- spotty-test -->', REVIEWER_LOGIN='opencode-agent',
                        LEGACY_UNMARKED_THREADS='false', CAN_APPROVE='true', REVIEWER_NAME='Test review',
                        REVIEW_REASON='fixture', RERUN_COMMAND='@test review', GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='1')
        self.write([], [{'id': 'thread', 'reply': 'Verified fixed.', 'resolve': True}])
        self.calls = []
        self.fail = None
        self.truncated = False
        self.current_head = self.env['HEAD_SHA']
        self.pending_state = 'PENDING'
        self.extra = []

    def write(self, findings, actions):
        (self.directory / 'findings.json').write_text(json.dumps(findings))
        (self.directory / 'thread-actions.json').write_text(json.dumps(actions))
        (self.directory / 'summary.md').write_text('Inspected fixture. Literal $(touch unexpected).')

    def request(self, method, endpoint, payload=None):
        self.calls.append((method, endpoint, payload))
        if self.fail:
            self.fail(method, endpoint, payload)
        if endpoint.endswith('/reviews'):
            self.assertNotIn('event', payload)
            return {'id': 12, 'node_id': 'pending-review'}
        if endpoint.endswith('/events'):
            self.pending_state = 'COMMENTED'
            return {'state': self.pending_state}
        if endpoint.endswith('/reviews/12'):
            return {'state': self.pending_state}
        if endpoint == 'graphql':
            if payload['query'].startswith('query'):
                thread = {'id': 'thread', 'isResolved': False, 'comments': {'nodes': [
                    {'author': {'login': 'opencode-agent'}, 'body': self.env['REVIEW_MARKER'] + '\nfinding',
                     'pullRequestReview': {'state': 'COMMENTED'}}]}}
                return {'data': {'repository': {'pullRequest': {'reviewThreads': {
                    'pageInfo': {'hasNextPage': self.truncated}, 'nodes': [thread] + self.extra}}}}}
            return {'data': {}}
        return {'head': {'sha': self.current_head}, 'state': 'open', 'draft': False}

    def run_publish(self):
        publisher.publish(self.env, self.request, lambda seconds: None)

    def submitted(self):
        return [call[2] for call in self.calls if call[1].endswith('/events')]

    def resolved(self):
        return [call for call in self.calls if call[1] == 'graphql' and 'resolveReviewThread' in call[2]['query']]

    def test_reply_and_inline_finding_share_one_review_before_resolution(self):
        self.write([{'path': 'file', 'line': 2, 'body': '[P2] Finding'}],
                   [{'id': 'thread', 'reply': 'Verified fixed.', 'resolve': True}])
        self.run_publish()
        self.assertEqual(len([call for call in self.calls if call[1].endswith('/reviews')]), 1)
        reply = next(call for call in self.calls if call[1] == 'graphql' and 'addPullRequestReviewThreadReply' in call[2]['query'])
        self.assertEqual(reply[2]['variables']['review'], 'pending-review')
        self.assertEqual(self.submitted()[0]['event'], 'COMMENT')
        submit_index = next(i for i, call in enumerate(self.calls) if call[1].endswith('/events'))
        self.assertGreater(self.calls.index(self.resolved()[0]), submit_index)
        self.assertIn('Literal $(touch unexpected).', self.submitted()[0]['body'])
        self.assertFalse((self.directory / 'unexpected').exists())

    def test_verified_disposition_allows_approval_but_docs_never_approves(self):
        self.run_publish()
        self.assertEqual(self.submitted()[0]['event'], 'APPROVE')
        self.calls.clear()
        self.env['CAN_APPROVE'] = 'false'
        self.run_publish()
        self.assertEqual(self.submitted()[0]['event'], 'COMMENT')

    def test_unresolved_or_truncated_history_withholds_approval(self):
        self.write([], [{'id': 'thread', 'reply': '', 'resolve': False}])
        self.run_publish()
        self.assertEqual(self.submitted()[0]['event'], 'COMMENT')
        self.truncated = True
        self.calls.clear()
        self.write([], [{'id': 'thread', 'reply': 'Fixed.', 'resolve': True}])
        self.run_publish()
        self.assertEqual(self.submitted()[0]['event'], 'COMMENT')
        self.assertEqual(self.resolved(), [])

    def test_moved_head_withholds_approval_and_resolution(self):
        self.current_head = 'b' * 40
        self.run_publish()
        self.assertEqual(self.submitted()[0]['event'], 'COMMENT')
        self.assertEqual(self.resolved(), [])

    def test_failed_reply_or_submission_leaves_threads_open_and_pending_is_cleaned(self):
        for failing_stage in ('reply', 'submission'):
            with self.subTest(failing_stage=failing_stage):
                self.calls.clear()
                self.pending_state = 'PENDING'
                def fail(method, endpoint, payload):
                    if (failing_stage == 'reply' and endpoint == 'graphql' and 'addPullRequestReviewThreadReply' in payload['query']) or (failing_stage == 'submission' and endpoint.endswith('/events')):
                        raise failure(503)
                self.fail = fail
                with self.assertRaises(publisher.APIError):
                    self.run_publish()
                self.assertEqual(self.resolved(), [])
                self.fail = None
                publisher.cleanup(self.env, self.request)
                self.assertIn(('DELETE', 'repos/owner/repo/pulls/1/reviews/12', None), self.calls)

    def test_cleanup_finds_only_this_run_after_uncertain_creation(self):
        marker = '<!-- reviewer -->\n<!-- pending-run:123:1 -->'
        (self.directory / 'pending.json').write_text(json.dumps({'id': None, 'marker': marker}))
        def request(method, endpoint, payload=None):
            if endpoint == 'graphql':
                self.assertIn('states: PENDING', payload['query'])
                return {'data': {'repository': {'pullRequest': {'reviews': {'nodes': [
                    {'databaseId': 12, 'body': marker + '\nSummary'},
                    {'databaseId': 99, 'body': 'Another publisher'}]}}}}}
            return self.request(method, endpoint, payload)
        publisher.cleanup(self.env, request)
        self.assertIn(('DELETE', 'repos/owner/repo/pulls/1/reviews/12', None), self.calls)
        self.assertFalse(any('/99' in call[1] for call in self.calls))

    def test_cleanup_never_deletes_submitted_review(self):
        self.run_publish()
        publisher.cleanup(self.env, self.request)
        self.assertFalse(any(call[0] == 'DELETE' for call in self.calls))

    def test_pending_conflict_retries_without_deleting_other_reviewer(self):
        count = 0
        def fail(method, endpoint, payload):
            nonlocal count
            if endpoint.endswith('/reviews'):
                count += 1
                if count == 1:
                    raise failure(422, 'User can only have one pending review per pull request')
        self.fail = fail
        self.run_publish()
        self.assertEqual(count, 2)
        self.assertEqual(len(self.submitted()), 1)
        self.assertFalse(any(call[0] == 'DELETE' for call in self.calls))

    def test_invalid_inline_placement_falls_back_but_network_failure_is_not_retried(self):
        self.write([{'path': 'binary', 'line': 1, 'body': '[P2] Finding'}], [])
        def fail(method, endpoint, payload):
            if endpoint.endswith('/reviews') and payload['comments']:
                raise failure(422)
        self.fail = fail
        self.run_publish()
        self.assertIn('Findings (inline placement rejected)', self.submitted()[0]['body'])
        self.calls.clear()
        self.fail = lambda *_: (_ for _ in ()).throw(failure(503))
        with self.assertRaises(publisher.APIError):
            self.run_publish()
        self.assertEqual(len(self.calls), 1)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        original = Path.cwd()
        os.chdir(self.directory)
        self.addCleanup(os.chdir, original)
        for args in (['init', '-q'], ['-c', 'user.name=Fixture', '-c', 'user.email=test@example.invalid',
                                    'commit', '--allow-empty', '-qm', 'fixture']):
            subprocess.run(['git'] + args, check=True, capture_output=True)
        self.head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
        self.context = dict(repository='owner/repo', pr=1, head=self.head, base=self.head, base_branch='main')
        for key in ('pr_description', 'pr_diff', 'changes_diff', 'threads'):
            path = self.directory / key
            path.write_text('fixture')
            self.context[key] = str(path)

    def fetch(self, endpoint):
        if '/rules/' in endpoint:
            return [{'type': 'pull_request', 'parameters': {'required_approving_review_count': 1,
                     'dismiss_stale_reviews_on_push': True}, 'bypass_actors': ['SECRET']}]
        if '/check-runs?' in endpoint:
            return {'total_count': 1, 'check_runs': [{'name': 'CI', 'head_sha': self.head,
                    'status': 'completed', 'conclusion': 'success', 'output': {'text': 'SECRET'}}]}
        if '/jobs?' in endpoint:
            return {'total_count': 1, 'jobs': [{'name': 'macOS checks', 'head_sha': self.head, 'steps': [
                    {'name': 'Run checks', 'status': 'completed', 'conclusion': 'success', 'log': 'SECRET'}]}]}
        return {'workflow_runs': [{'id': 123, 'run_attempt': 2, 'head_sha': self.head,
                                  'status': 'completed', 'conclusion': 'success'}]}

    def test_preflight_supplies_sanitized_settings_and_head_matched_runtime(self):
        result = evidence.collect(self.context, self.directory, self.fetch)
        inputs = {item['name']: item for item in result['inputs']}
        for name in ('branch_rules', 'check_runs', 'ci_runtime', 'source_and_history', 'threads'):
            self.assertEqual(inputs[name]['status'], 'present')
        rules = json.loads(Path(inputs['branch_rules']['path']).read_text())
        self.assertEqual(rules['data'][0]['parameters']['required_approving_review_count'], 1)
        runtime = json.loads(Path(inputs['ci_runtime']['path']).read_text())
        self.assertEqual(runtime['data']['jobs'][0]['steps'][0]['conclusion'], 'success')
        self.assertEqual(runtime['data']['run']['head_sha'], self.head)
        self.assertIn('/attempts/2/jobs?', runtime['data']['jobs_endpoint'])
        self.assertNotIn('SECRET', ''.join(path.read_text() for path in self.directory.glob('*.json')))
        self.assertEqual(inputs['ui_runtime_report']['status'], 'not_supplied')

    def test_failed_nested_endpoint_is_named_and_missing_report_is_not_gh_access_failure(self):
        def fetch(endpoint):
            if '/jobs?' in endpoint:
                raise evidence.EvidenceUnavailable(endpoint, 'HTTP 403')
            return self.fetch(endpoint)
        Path(self.context['pr_description']).unlink()
        result = evidence.collect(self.context, self.directory, fetch)
        inputs = {item['name']: item for item in result['inputs']}
        self.assertEqual(inputs['ci_runtime']['status'], 'unavailable')
        self.assertIn('/attempts/2/jobs?', inputs['ci_runtime']['endpoint'])
        self.assertEqual(inputs['ci_runtime']['error'], 'HTTP 403')
        self.assertEqual(inputs['pr_description']['status'], 'missing')
        self.assertEqual(inputs['branch_rules']['status'], 'present')

    def test_old_head_or_pending_run_cannot_be_reported_as_passed_current_execution(self):
        def fetch(endpoint):
            if '/workflows/' in endpoint:
                return {'workflow_runs': [{'id': 999, 'head_sha': 'old'}]}
            return self.fetch(endpoint)
        evidence.collect(self.context, self.directory, fetch)
        runtime = json.loads((self.directory / 'ci-runtime.json').read_text())
        self.assertEqual(runtime['data']['status'], 'not_started')
        self.assertEqual(runtime['data']['runs'], [])


if __name__ == '__main__':
    unittest.main()
