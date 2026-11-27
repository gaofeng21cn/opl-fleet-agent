import assert from 'node:assert/strict';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { handleRequest } from '../bin/opl-fleet-agent.mjs';

const pluginRoot = path.resolve(import.meta.dirname, '..');
const repositoryRoot = path.resolve(pluginRoot, '..', '..');

const request = (ref) => ({
  schema_version: 'opl-package-app-contribution-request.v1',
  package_id: 'opl-fleet-agent',
  operation: 'read',
  ref,
  input: {},
});

test('keeps Agent Plugins 1.0 authority aligned with the Codex compatibility manifest', async () => {
  const authority = JSON.parse(await readFile(path.join(pluginRoot, 'plugin.json'), 'utf8'));
  const compatibility = JSON.parse(
    await readFile(path.join(pluginRoot, '.codex-plugin', 'plugin.json'), 'utf8'),
  );
  const descriptor = JSON.parse(await readFile(path.join(pluginRoot, 'opl-package.json'), 'utf8'));

  assert.equal(authority.$schema, 'https://agent-plugins.org/schemas/1.0.0/plugin.schema.json');
  assert.equal(authority.name, compatibility.name);
  assert.equal(authority.version, compatibility.version);
  assert.equal(descriptor.identity.version, authority.version);
  assert.deepEqual(authority.extensions?.['com.openai']?.interface, compatibility.interface);
  assert.equal('skills' in authority, false);
  assert.equal('interface' in authority, false);
});

test('declares the read-only integration and its Framework v2 contributions', async () => {
  const descriptor = JSON.parse(await readFile(path.join(pluginRoot, 'opl-package.json'), 'utf8'));
  assert.equal(descriptor.schema_version, 'opl.package.v2');
  assert.equal(descriptor.identity.id, 'opl-fleet-agent');
  assert.equal(descriptor.identity.publisher, 'one-person-lab');
  assert.equal(descriptor.dependencies.opl_base, '^2.0.0');
  assert.deepEqual(descriptor.provides.module_ids, [
    'fleet.agent.telemetry.v1',
    'fleet.agent.doctor.v1',
  ]);
  assert.deepEqual(descriptor.provides.contribution_handler, {
    kind: 'cli',
    argv: ['node', './bin/opl-fleet-agent.mjs'],
    transport: 'stdin_json_stdout_json',
  });
  assert.deepEqual(
    descriptor.ui.declarative.views.map(({ id, slot, data_ref, sort_order }) => ({
      id,
      slot,
      data_ref,
      sort_order,
    })),
    [
      {
        id: 'fleet.agent.telemetry',
        slot: 'settings.section',
        data_ref: 'fleet.agent.telemetry.v1#local',
        sort_order: 1300,
      },
      {
        id: 'fleet.agent.doctor',
        slot: 'settings.section',
        data_ref: 'fleet.agent.doctor.v1#current',
        sort_order: 1301,
      },
    ],
  );
});

test('exposes one configured native Codex marketplace carrier', async () => {
  const marketplace = JSON.parse(
    await readFile(path.join(repositoryRoot, '.agents', 'plugins', 'marketplace.json'), 'utf8'),
  );
  const descriptor = JSON.parse(await readFile(path.join(pluginRoot, 'opl-package.json'), 'utf8'));

  assert.equal(marketplace.name, 'opl-fleet-agent');
  assert.deepEqual(marketplace.plugins, [{
    name: 'opl-fleet-agent',
    source: {
      source: 'local',
      path: './plugins/opl-fleet-agent',
    },
    policy: {
      installation: 'AVAILABLE',
      authentication: 'ON_INSTALL',
    },
    category: 'Productivity',
  }]);
  assert.equal(
    path.resolve(repositoryRoot, marketplace.plugins[0].source.path),
    pluginRoot,
  );
  assert.equal(descriptor.host_hints.codex.plugin_name, 'opl-fleet-agent');
});

test('uses the OPL registry and preserves Codex host metadata', async () => {
  const descriptor = JSON.parse(await readFile(path.join(pluginRoot, 'opl-package.json'), 'utf8'));
  assert.deepEqual(descriptor.distribution, {
    oci: 'ghcr.io/gaofeng21cn/one-person-lab-packages/opl-fleet-agent',
    visibility: 'public',
  });
  assert.deepEqual(descriptor.host_hints.codex, {
    sync_enabled: false,
    plugin_name: 'opl-fleet-agent',
    category: 'Productivity',
    capabilities: ['Local telemetry', 'Node doctor'],
  });
});

test('rejects unknown refs without invoking native code', async () => {
  const response = await handleRequest(request('fleet.agent.telemetry.v1#unknown'), {});

  assert.equal(response.code, 2);
  assert.equal(response.payload.ok, false);
  assert.match(response.payload.error.message, /not declared/);
});

test('rejects a contribution request for a different Package identity', async () => {
  const response = await handleRequest({
    ...request('fleet.agent.telemetry.v1#local'),
    package_id: 'another-package',
  }, {});

  assert.equal(response.code, 2);
  assert.equal(response.payload.ok, false);
  assert.match(response.payload.error.message, /package_id must be opl-fleet-agent/);
});

test('returns a valid unavailable projection when the optional native helper is absent', async () => {
  const response = await handleRequest(request('fleet.agent.telemetry.v1#local'), {
    OPL_FLEET_AGENT_PROVIDER_BIN: path.join(tmpdir(), 'definitely-not-installed-provider'),
  });

  assert.equal(response.code, 0);
  assert.equal(response.payload.ok, true);
  assert.equal(response.payload.result.schema, 'opl_fleet_agent_provider.v1');
  assert.equal(response.payload.result.native_carrier.availability, 'unavailable');
  assert.equal(response.payload.result.native_carrier.status, 'not_running');
  assert.equal(response.payload.result.node, null);
  assert.equal(response.payload.result.freshness.state, 'unavailable');
  assert.equal(response.payload.result.freshness.last_observed_at, null);
  assert.equal(response.payload.result.freshness.reason_code, 'native_provider_not_installed');
  assert.equal(response.payload.result.payload.collection_status, 'unavailable');
  assert.equal(response.payload.result.payload.windows.one_minute.token_rate_per_second, null);
  assert.deepEqual(response.payload.result.payload.host_capability_flags, []);
});

test('forwards a sanitized native projection', async (t) => {
  const directory = await mkdtemp(path.join(tmpdir(), 'opl-fleet-provider-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const helper = await writeHelper(directory, {
    schema: 'opl_fleet_agent_provider.v1',
    capability_abi: { id: 'opl-fleet-agent.capabilities', version: '1.0.0' },
    access: 'read_only',
    authority: 'observation_only',
    operation: 'doctor.read',
    read_ref: 'fleet.agent.doctor.v1#current',
    observed_at: '2026-08-16T00:00:00.000Z',
    freshness: {
      state: 'fresh',
      last_observed_at: '2026-08-16T00:00:00.000Z',
      last_known: false,
    },
    native_carrier: { kind: 'opl_fleet_agent_process', availability: 'available', status: 'ready' },
    node: {
      stable_node_id: 'fixture-node',
      display_name: 'Fixture Node',
      platform: 'test',
      agent_version: '0.2.40',
    },
    payload: { doctor_state: 'healthy', capability_currentness: 'current', checks: [] },
  });

  const response = await handleRequest(request('fleet.agent.doctor.v1#current'), {
    OPL_FLEET_AGENT_PROVIDER_BIN: helper,
  });

  assert.equal(response.code, 0);
  assert.equal(response.payload.result.payload.doctor_state, 'healthy');
});

test('discovers the canonical current-user macOS app helper', {
  skip: process.platform !== 'darwin',
}, async (t) => {
  const home = await mkdtemp(path.join(tmpdir(), 'opl-fleet-provider-home-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const helper = path.join(
    home,
    'Applications',
    'OPL Fleet Agent.app',
    'Contents',
    'MacOS',
    'OPLFleetAgentProvider',
  );
  await mkdir(path.dirname(helper), { recursive: true });
  await writeHelperAt(helper, {
    schema: 'opl_fleet_agent_provider.v1',
    capability_abi: { id: 'opl-fleet-agent.capabilities', version: '1.0.0' },
    access: 'read_only',
    authority: 'observation_only',
    operation: 'doctor.read',
    read_ref: 'fleet.agent.doctor.v1#current',
    observed_at: '2026-08-16T00:00:00.000Z',
    freshness: {
      state: 'fresh',
      last_observed_at: '2026-08-16T00:00:00.000Z',
      last_known: false,
    },
    native_carrier: { kind: 'opl_fleet_agent_process', availability: 'available', status: 'ready' },
    node: {
      stable_node_id: 'fixture-node',
      display_name: 'Fixture Node',
      platform: 'test',
      agent_version: '0.2.40',
    },
    payload: { doctor_state: 'healthy', capability_currentness: 'current', checks: [] },
  });

  const response = await handleRequest(request('fleet.agent.doctor.v1#current'), { HOME: home });

  assert.equal(response.code, 0);
  assert.equal(response.payload.result.native_carrier.availability, 'available');
  assert.equal(response.payload.result.payload.doctor_state, 'healthy');
});

test('fails closed on recursively sensitive native keys without exposing helper output', async (t) => {
  const directory = await mkdtemp(path.join(tmpdir(), 'opl-fleet-provider-privacy-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const helper = await writeHelper(directory, {
    schema: 'opl_fleet_agent_provider.v1',
    capability_abi: { id: 'opl-fleet-agent.capabilities', version: '1.0.0' },
    access: 'read_only',
    authority: 'observation_only',
    operation: 'telemetry.read',
    read_ref: 'fleet.agent.telemetry.v1#local',
    observed_at: '2026-08-16T00:00:00.000Z',
    freshness: {
      state: 'fresh',
      last_observed_at: '2026-08-16T00:00:00.000Z',
      last_known: false,
    },
    native_carrier: { kind: 'opl_fleet_agent_process', availability: 'available', status: 'ready' },
    node: {
      stable_node_id: 'fixture-node',
      display_name: 'Fixture Node',
      platform: 'test',
      agent_version: '0.2.40',
    },
    payload: { nested: { prompt: 'must-never-escape' } },
  });

  const response = await handleRequest(request('fleet.agent.telemetry.v1#local'), {
    OPL_FLEET_AGENT_PROVIDER_BIN: helper,
  });

  assert.equal(response.code, 0);
  assert.equal(response.payload.result.freshness.state, 'unavailable');
  assert.equal(response.payload.result.freshness.reason_code, 'native_provider_privacy_rejected');
  assert.doesNotMatch(JSON.stringify(response.payload), /must-never-escape/);
});

test('fails closed when native unavailable freshness still carries observations', async (t) => {
  const directory = await mkdtemp(path.join(tmpdir(), 'opl-fleet-provider-contract-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const helper = await writeHelper(directory, {
    schema: 'opl_fleet_agent_provider.v1',
    capability_abi: { id: 'opl-fleet-agent.capabilities', version: '1.0.0' },
    access: 'read_only',
    authority: 'observation_only',
    operation: 'telemetry.read',
    read_ref: 'fleet.agent.telemetry.v1#local',
    observed_at: '2026-08-16T00:00:00.000Z',
    freshness: {
      state: 'unavailable',
      last_observed_at: null,
      last_known: false,
      reason_code: 'usage_source_unavailable',
    },
    native_carrier: { kind: 'opl_fleet_agent_process', availability: 'available', status: 'degraded' },
    node: {
      stable_node_id: 'fixture-node',
      display_name: 'Fixture Node',
      platform: 'test',
      agent_version: '0.2.40',
    },
    payload: {
      collection_status: 'unavailable',
      windows: {
        one_minute: {
          window_seconds: 60,
          token_rate_per_second: 1,
          request_rate_per_minute: null,
        },
        five_minutes: {
          window_seconds: 300,
          token_rate_per_second: null,
          request_rate_per_minute: null,
        },
      },
      active_conversation_count: null,
      host_cpu_percent: null,
      host_network_receive_bytes_per_second: null,
      host_network_transmit_bytes_per_second: null,
      host_capability_flags: [],
    },
  });

  const response = await handleRequest(request('fleet.agent.telemetry.v1#local'), {
    OPL_FLEET_AGENT_PROVIDER_BIN: helper,
  });

  assert.equal(response.code, 0);
  assert.equal(response.payload.result.freshness.state, 'unavailable');
  assert.equal(response.payload.result.freshness.reason_code, 'native_provider_invalid_response');
  assert.equal(response.payload.result.payload.windows.one_minute.token_rate_per_second, null);
});

async function writeHelper(directory, payload) {
  if (process.platform === 'win32') {
    const file = path.join(directory, 'provider.cmd');
    await writeFile(file, `@echo off\r\necho ${JSON.stringify(payload)}\r\n`);
    return file;
  }
  const file = path.join(directory, 'provider');
  await writeHelperAt(file, payload);
  return file;
}

async function writeHelperAt(file, payload) {
  await writeFile(file, `#!/bin/sh\nprintf '%s\\n' '${JSON.stringify(payload)}'\n`);
  await chmod(file, 0o755);
}
