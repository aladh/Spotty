import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';
import { Evaluator, Lexer, Parser, data } from '@actions/expressions';

const root = fileURLToPath(new URL('../../', import.meta.url));
function workflow(name) {
  return JSON.parse(execFileSync('ruby', ['-ryaml', '-rjson', '-e',
    'puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))',
    join(root, '.github/workflows', name)], { encoding: 'utf8' }));
}
function value(input) {
  if (input === null || input === undefined) return new data.Null();
  if (Array.isArray(input)) return new data.Array(...input.map(value));
  if (typeof input === 'object') return new data.Dictionary(
    ...Object.entries(input).map(([key, item]) => ({ key, value: value(item) })));
  if (typeof input === 'boolean') return new data.BooleanData(input);
  if (typeof input === 'number') return new data.NumberData(input);
  return new data.StringData(input);
}
function evaluate(expression, context) {
  const tokens = new Lexer(expression.replace(/^\s*\$\{\{|\}\}\s*$/g, '')).lex().tokens;
  const parsed = new Parser(tokens, Object.keys(context), []).parse();
  return new Evaluator(parsed, value(context)).evaluate().coerceString();
}
function render(template, context) {
  return template.replace(/\$\{\{([\s\S]*?)\}\}/g, (_, expression) => evaluate(expression, context));
}
function event(kind, id = 100) {
  return {
    inputs: {},
    github: {
      event_name: kind, run_id: id, repository: 'aladh/Spotty', ref: 'refs/heads/main',
      event: { repository: { default_branch: 'main' } },
    },
  };
}
function pullRequest(id = 100, number = 472) {
  const context = event('pull_request', id);
  context.github.event.pull_request = {
    number, draft: false, head: { repo: { full_name: 'aladh/Spotty' } },
  };
  return context;
}
function comment(body, association = 'OWNER', id = 100) {
  const context = event('issue_comment', id);
  context.github.event.issue = { number: 472, pull_request: {} };
  context.github.event.comment = { body, author_association: association };
  return context;
}
function dispatch(id = 100) {
  const context = event('workflow_dispatch', id);
  context.inputs.pr_number = '472';
  return context;
}
const reviewers = [
  ['thermos-review.yml', '@thermos review'],
  ['docs-review.yml', '@docs-review review'],
];
for (const [file, command] of reviewers) {
  const caller = workflow(file);
  const job = Object.values(caller.jobs)[0];
  const group = context => render(caller.concurrency.group, context);
  const eligible = context => evaluate(job.if, context) === 'true';

  test(`${file}: valid reruns and newer heads share only their PR's group`, () => {
    const original = group(pullRequest());
    assert.equal(caller.concurrency['cancel-in-progress'], true);
    assert.equal(eligible(pullRequest()), true);
    assert.equal(group(pullRequest(101)), original);
    assert.equal(group(dispatch(102)), original);
    assert.equal(eligible(dispatch()), true);
    for (const association of ['OWNER', 'MEMBER', 'COLLABORATOR']) {
      const requested = comment(`Please ${command}`, association);
      assert.equal(eligible(requested), true, association);
      assert.equal(group(requested), original, association);
    }
    assert.notEqual(group(pullRequest(103, 473)), original);
    assert.equal(job.with.rerun_command, command);
  });

  test(`${file}: ignored events cannot cancel running or evict pending reviews`, () => {
    const contexts = [
      comment('Routine bot summary', 'NONE'),
      comment('Thanks for the review'),
      comment(command, 'CONTRIBUTOR'),
      comment(command, 'FIRST_TIME_CONTRIBUTOR'),
      comment(command, 'NONE'),
      comment(file.startsWith('thermos') ? '@docs-review review' : '@thermos review'),
      event('push'),
    ];
    const issue = comment(command);
    delete issue.github.event.issue.pull_request;
    contexts.push(issue);
    const draft = pullRequest();
    draft.github.event.pull_request.draft = true;
    contexts.push(draft);
    const fork = pullRequest();
    fork.github.event.pull_request.head.repo.full_name = 'someone/Spotty';
    contexts.push(fork);
    const wrongBranch = dispatch();
    wrongBranch.github.ref = 'refs/heads/untrusted';
    contexts.push(wrongBranch);
    const activeGroup = group(pullRequest(1));
    const pendingGroup = group(pullRequest(2));
    assert.equal(pendingGroup, activeGroup);
    for (const [index, ignored] of contexts.entries()) {
      ignored.github.run_id = 200 + index;
      assert.equal(eligible(ignored), false, JSON.stringify(ignored));
      assert.notEqual(group(ignored), activeGroup);
      assert.notEqual(group(ignored), pendingGroup);
      const next = structuredClone(ignored);
      next.github.run_id += 100;
      assert.notEqual(group(next), group(ignored));
    }
  });
}

test('reviewers do not cancel each other for the same PR', () => {
  assert.notEqual(
    render(workflow('thermos-review.yml').concurrency.group, pullRequest()),
    render(workflow('docs-review.yml').concurrency.group, pullRequest()));
});

const shared = workflow('agent-review.yml');
const steps = shared.jobs.review.steps;
function temporary(run) {
  const directory = mkdtempSync(join(tmpdir(), 'spotty-review-test-'));
  try { run(directory); } finally { rmSync(directory, { recursive: true, force: true }); }
}

test('both published review bodies include the trusted-collaborator rerun hint', () => temporary(directory => {
  writeFileSync(join(directory, 'summary.md'), 'No findings. Literal $(touch unexpected).');
  const publish = steps.find(step => step.name === 'Publish review').run;
  // Execute the production body construction with literal, potentially hostile summary text.
  const formatBody = publish.split('\n').filter(line => /^(rerun_hint|body)=/.test(line)).join('\n');
  assert.notEqual(formatBody, '');
  for (const [file, command] of reviewers) {
    const result = execFileSync('bash', ['-eu', '-c', `${formatBody}\nprintf '%s' "$body"`], {
      cwd: directory, encoding: 'utf8',
      env: { ...process.env, REVIEW_MARKER: '<!-- reviewer -->', header: 'Review of head', RERUN_COMMAND: command },
    });
    assert.match(result, /Trusted repository collaborators/);
    assert.ok(result.includes(`\`${command}\``), file);
    assert.ok(result.includes('Literal $(touch unexpected).'));
  }
  assert.throws(() => readFileSync(join(directory, 'unexpected')), { code: 'ENOENT' });
}));

test('documentation review reaches the agent even when no documentation changed', () => {
  const context = { steps: { eligibility: { outputs: { skip: 'false' } }, 'path-filter': { outputs: { skip: 'true' } } } };
  assert.equal(evaluate(steps.find(step => step.name === 'Prepare review inputs').if, context), 'true');
  assert.equal(evaluate(steps.find(step => step.name === 'Review').if, context), 'true');
  assert.equal(Object.values(workflow('docs-review.yml').jobs)[0].with.can_approve, 'false');
});

for (const includeDocs of [false, true]) {
  test(`review inputs retain implementation changes (docs changed: ${includeDocs})`, () => temporary(directory => {
    const git = (...args) => execFileSync('git', args, { cwd: directory, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
    git('init', '-q');
    git('config', 'user.name', 'Fixture');
    git('config', 'user.email', 'fixture@example.invalid');
    mkdirSync(join(directory, 'Sources'));
    writeFileSync(join(directory, 'Sources/Feature.swift'), 'let label = "Before"\n');
    writeFileSync(join(directory, 'README.md'), 'Original documentation\n');
    git('add', '.'); git('commit', '-qm', 'Base');
    const base = git('rev-parse', 'HEAD');
    writeFileSync(join(directory, 'Sources/Feature.swift'), 'let label = "After"\n');
    if (includeDocs) writeFileSync(join(directory, 'README.md'), 'Updated documentation\n');
    git('add', '.'); git('commit', '-qm', 'Change');
    const head = git('rev-parse', 'HEAD');
    const bin = join(directory, 'bin');
    mkdirSync(bin);
    writeFileSync(join(bin, 'gh'), `#!/bin/sh
case "$*" in
  'api graphql '*) printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}' ;;
  *) printf '%s' '{"title":"Fixture","body":"Implementation change"}' ;;
esac
`, { mode: 0o755 });
    const input = join(directory, 'in');
    const result = spawnSync('bash', ['-eu', '-c', steps.find(step => step.name === 'Prepare review inputs').run], {
      cwd: directory, encoding: 'utf8', env: {
        ...process.env, PATH: `${bin}:${process.env.PATH}`, GITHUB_REPOSITORY: 'aladh/Spotty',
        GITHUB_ENV: join(directory, 'env'), PR_NUMBER: '472', BASE_SHA: base, HEAD_SHA: head,
        PREVIOUS_HEAD: '', REVIEW_MODE: 'full', REVIEW_REASON: 'fixture', REVIEWER_LOGIN: 'opencode-agent',
        REVIEW_MARKER: '<!-- spotty-docs-review -->', REVIEWER_NAME: 'Documentation review',
        LEGACY_UNMARKED_THREADS: 'false', REVIEW_IN: input, REVIEW_OUT: join(directory, 'out'),
        PATH_REGEX: '^(docs/|README\\.md$)',
      },
    });
    assert.equal(result.status, 0, result.stderr);
    const diff = readFileSync(join(input, 'changes.diff'), 'utf8');
    assert.ok(diff.includes('Sources/Feature.swift'));
    assert.equal(diff.includes('README.md'), includeDocs);
    const context = JSON.parse(readFileSync(join(input, 'context.json'), 'utf8'));
    assert.equal(context.head, head);
    assert.deepEqual(JSON.parse(readFileSync(context.threads, 'utf8')), []);
    assert.match(readFileSync(context.pr_description, 'utf8'), /Implementation change/);
  }));
}
