import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmod, copyFile, cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';

const packageRoot = path.resolve(import.meta.dirname, '..');
const sourceRoot = path.resolve(packageRoot, '..', '..');

test('relocated Package reads the same isolated native node and preserves last-known observation', {
  skip: process.platform !== 'darwin',
}, async (t) => {
  const directory = await mkdtemp(path.join(tmpdir(), 'opl-fleet-native-carrier-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const carrier = path.join(directory, 'package');
  await cp(packageRoot, carrier, { recursive: true });
  const native = path.join(directory, 'OPL Fleet Agent.app', 'Contents', 'MacOS', 'OPLFleetAgentProvider');
  await mkdir(path.dirname(native), { recursive: true });
  await copyFile(path.join(sourceRoot, '.build', 'debug', 'OPLFleetAgentProvider'), native);
  await chmod(native, 0o755);
  const fixtureCodexHome = path.join(directory, 'codex');
  const sessions = path.join(fixtureCodexHome, 'sessions');
  await mkdir(sessions, { recursive: true });
  const timestamp = new Date(Date.now() - 5_000).toISOString();
  await writeFile(path.join(sessions, 'rollout-fixture.jsonl'), [
    { timestamp, type: 'session_meta', payload: { id: 'isolated-fixture', model_provider: 'fixture' } },
    { timestamp, type: 'turn_context', payload: { model: 'fixture-model' } },
    { timestamp, type: 'event_msg', payload: { type: 'token_count', info: {
      total_token_usage: { input_tokens: 100, output_tokens: 20, total_tokens: 120 },
      last_token_usage: { input_tokens: 100, output_tokens: 20, total_tokens: 120 },
    } } },
  ].map((value) => JSON.stringify(value)).join('\n') + '\n');
  const environment = {
    ...process.env,
    CODEX_HOME: fixtureCodexHome,
    OPL_FLEET_AGENT_PROVIDER_BIN: native,
    OPL_FLEET_AGENT_PROVIDER_CACHE: path.join(directory, 'last-known.json'),
    OPL_FLEET_AGENT_MACHINE_ID: 'isolated-node',
    OPL_FLEET_AGENT_MACHINE_NAME: 'Isolated Node',
    OPL_FLEET_AGENT_PLATFORM: 'macOS',
  };
  const descriptor = JSON.parse(await readFile(path.join(carrier, 'opl-package.json'), 'utf8'));
  const handler = descriptor.provides.contribution_handler;
  assert.equal(handler.kind, 'cli');
  assert.equal(handler.transport, 'stdin_json_stdout_json');
  const [command, ...args] = handler.argv;
  const read = (viewId) => {
    const view = descriptor.ui.declarative.views.find(({ id }) => id === viewId);
    assert.ok(view, `Missing declared view: ${viewId}`);
    const ref = view.data_ref;
    const execution = spawnSync(command, args, {
      cwd: carrier,
      env: environment,
      input: JSON.stringify({
        schema_version: 'opl-package-app-contribution-request.v1',
        package_id: descriptor.identity.id,
        operation: 'read',
        ref,
        input: {},
      }),
      encoding: 'utf8',
    });
    assert.equal(execution.status, 0, execution.stderr);
    const response = JSON.parse(execution.stdout);
    assert.equal(response.ok, true);
    assert.equal(response.ref, ref);
    return response.result;
  };
  const first = read('fleet.agent.telemetry');
  assert.equal(first.node.stable_node_id, 'isolated-node');
  assert.equal(first.freshness.state, 'fresh');
  assert.equal(first.payload.windows.one_minute.token_rate_per_second, 2);
  await rm(sessions, { recursive: true });
  const stale = read('fleet.agent.telemetry');
  const doctor = read('fleet.agent.doctor');
  for (const projection of [stale, doctor]) {
    assert.deepEqual(projection.node, first.node);
    assert.equal(projection.freshness.state, 'stale');
    assert.equal(projection.freshness.last_known, true);
    assert.equal(projection.freshness.last_observed_at, first.freshness.last_observed_at);
    assert.equal(projection.authority, 'observation_only');
    assert.equal(projection.access, 'read_only');
  }
  assert.deepEqual(stale.payload, { ...first.payload, collection_status: 'degraded' });
  await rm(environment.OPL_FLEET_AGENT_PROVIDER_CACHE);
  const unavailable = read('fleet.agent.telemetry');
  assert.equal(unavailable.freshness.state, 'unavailable');
  assert.equal(unavailable.freshness.last_observed_at, null);
  assert.equal(unavailable.payload.windows.one_minute.token_rate_per_second, null);
});
