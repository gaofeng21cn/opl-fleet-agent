#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { pathToFileURL } from 'node:url';

const REQUEST_SCHEMA = 'opl-package-app-contribution-request.v1';
const RESPONSE_SCHEMA = 'opl-package-app-contribution-response.v1';
const PROVIDER_SCHEMA = 'opl_fleet_agent_provider.v1';
const CAPABILITY_ID = 'opl-fleet-agent.capabilities';
const CAPABILITY_VERSION = '1.0.0';

const CONTRACTS = new Map([
  ['fleet.agent.telemetry.v1#local', {
    providerOperation: 'telemetry.read',
    resultSchema: PROVIDER_SCHEMA,
  }],
  ['fleet.agent.doctor.v1#current', {
    providerOperation: 'doctor.read',
    resultSchema: PROVIDER_SCHEMA,
  }],
]);

const FORBIDDEN_KEY_PARTS = [
  'prompt',
  'response',
  'session',
  'path',
  'address',
  'credential',
  'secret',
  'raw_log',
  'rawlog',
];
const FORBIDDEN_AUTHORITY_KEYS = new Set([
  'admission',
  'lease',
  'dispatch',
  'task_completion',
  'completion_verdict',
]);

export async function handleRequest(request, environment = process.env) {
  let ref = null;
  try {
    assertObject(request, 'request');
    ref = typeof request.ref === 'string' ? request.ref : null;
    assertKeys(request, ['schema_version', 'operation', 'ref', 'input'], 'request', true);
    if (request.schema_version !== REQUEST_SCHEMA) {
      throw new RequestError(`schema_version must be ${REQUEST_SCHEMA}`);
    }
    if (request.operation !== 'read' && request.operation !== 'describe') {
      throw new RequestError('operation must be read or describe');
    }
    if (!ref || !CONTRACTS.has(ref)) {
      throw new RequestError('ref is not declared by this package');
    }
    const contract = CONTRACTS.get(ref);

    if (request.operation === 'describe') {
      if (Object.hasOwn(request, 'input')) {
        throw new RequestError('describe does not accept input');
      }
      return success(ref, 'describe', {
        abi: 'opl-package-app-contribution-cli.v1',
        request_schema: REQUEST_SCHEMA,
        response_schema: RESPONSE_SCHEMA,
        ref,
        operations: [{ operation: 'read', input: {}, result_schema: contract.resultSchema }],
      });
    }

    assertObject(request.input, 'input');
    assertKeys(request.input, [], 'input');
    const helper = resolveHelper(environment);
    if (helper === null) {
      return success(
        ref,
        'read',
        unavailableProjection(ref, 'native_provider_not_installed', 'not_running'),
      );
    }

    const execution = spawnSync(helper, ['--ref', ref], {
      encoding: 'utf8',
      env: environment,
      timeout: 5_000,
      windowsHide: true,
      maxBuffer: 1_048_576,
    });
    if (execution.error || execution.status !== 0) {
      return success(
        ref,
        'read',
        unavailableProjection(ref, 'native_provider_unreachable', 'unreachable'),
      );
    }

    let result;
    try {
      result = JSON.parse(execution.stdout);
    } catch {
      return success(
        ref,
        'read',
        unavailableProjection(ref, 'native_provider_invalid_response', 'unreachable'),
      );
    }
    if (containsForbiddenKey(result)) {
      return success(
        ref,
        'read',
        unavailableProjection(ref, 'native_provider_privacy_rejected', 'unreachable'),
      );
    }
    try {
      validateProviderResult(result, ref, contract.providerOperation);
    } catch {
      return success(
        ref,
        'read',
        unavailableProjection(ref, 'native_provider_invalid_response', 'unreachable'),
      );
    }
    return success(ref, 'read', result);
  } catch (error) {
    const message = error instanceof RequestError ? error.message : 'invalid request';
    return {
      code: 2,
      payload: {
        schema_version: RESPONSE_SCHEMA,
        ok: false,
        ref,
        error: { code: 'invalid_request', message },
      },
    };
  }
}

function success(ref, operation, result) {
  return {
    code: 0,
    payload: {
      schema_version: RESPONSE_SCHEMA,
      ok: true,
      ref,
      operation,
      result,
    },
  };
}

function resolveHelper(environment) {
  if (typeof environment.OPL_FLEET_AGENT_PROVIDER_BIN === 'string') {
    const configured = environment.OPL_FLEET_AGENT_PROVIDER_BIN.trim();
    return configured && existsSync(configured) ? configured : null;
  }
  const candidates = [];
  if (process.platform === 'darwin') {
    const home = typeof environment.HOME === 'string' ? environment.HOME.trim() : '';
    if (home) {
      candidates.push(path.join(
        home,
        'Applications',
        'OPL Fleet Agent.app',
        'Contents',
        'MacOS',
        'OPLFleetAgentProvider',
      ));
      candidates.push(path.join(
        home,
        'Applications',
        'Codex TPS.app',
        'Contents',
        'MacOS',
        'OPLFleetAgentProvider',
      ));
    }
    candidates.push('/Applications/OPL Fleet Agent.app/Contents/MacOS/OPLFleetAgentProvider');
    candidates.push('/Applications/Codex TPS.app/Contents/MacOS/OPLFleetAgentProvider');
  } else if (process.platform === 'win32') {
    const localAppData = environment.LOCALAPPDATA;
    if (localAppData) {
      candidates.push(path.join(
        localAppData,
        'Programs',
        'OPL Fleet Agent',
        'OPLFleetAgentProvider.exe',
      ));
    }
  }
  return candidates.find(existsSync) ?? null;
}

function unavailableProjection(ref, reasonCode, carrierStatus) {
  const telemetry = ref === 'fleet.agent.telemetry.v1#local';
  return {
    schema: PROVIDER_SCHEMA,
    capability_abi: { id: CAPABILITY_ID, version: CAPABILITY_VERSION },
    access: 'read_only',
    authority: 'observation_only',
    operation: telemetry ? 'telemetry.read' : 'doctor.read',
    read_ref: ref,
    observed_at: new Date().toISOString(),
    freshness: {
      state: 'unavailable',
      last_observed_at: null,
      last_known: false,
      reason_code: reasonCode,
    },
    native_carrier: {
      kind: 'opl_fleet_agent_process',
      availability: 'unavailable',
      status: carrierStatus,
    },
    node: null,
    payload: telemetry
      ? {
          collection_status: 'unavailable',
          windows: {
            one_minute: {
              window_seconds: 60,
              token_rate_per_second: null,
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
        }
      : {
          doctor_state: 'unavailable',
          capability_currentness: 'unavailable',
          checks: [],
        },
  };
}

function validateProviderResult(result, ref, operation) {
  assertObject(result, 'provider result');
  assertKeys(
    result,
    [
      'schema',
      'capability_abi',
      'access',
      'authority',
      'operation',
      'read_ref',
      'observed_at',
      'freshness',
      'native_carrier',
      'node',
      'payload',
    ],
    'provider result',
  );
  if (
    result.schema !== PROVIDER_SCHEMA
    || result.access !== 'read_only'
    || result.authority !== 'observation_only'
    || result.operation !== operation
    || result.read_ref !== ref
    || !isDateTime(result.observed_at)
  ) {
    throw new Error('provider envelope mismatch');
  }
  assertExactObject(
    result.capability_abi,
    ['id', 'version'],
    { id: CAPABILITY_ID, version: CAPABILITY_VERSION },
    'capability_abi',
  );
  assertExactObject(
    result.native_carrier,
    ['kind', 'availability', 'status'],
    { kind: 'opl_fleet_agent_process', availability: 'available' },
    'native_carrier',
  );
  if (!['ready', 'degraded'].includes(result.native_carrier.status)) {
    throw new Error('invalid native carrier status');
  }
  validateFreshness(result.freshness);
  validateNode(result.node);
  if (operation === 'telemetry.read') {
    validateTelemetry(result.payload, result.freshness);
  } else {
    validateDoctor(result.payload, result.freshness);
  }
}

function validateFreshness(value) {
  assertObject(value, 'freshness');
  assertKeys(value, ['state', 'last_observed_at', 'last_known', 'reason_code'], 'freshness', true);
  if (!['fresh', 'stale', 'unavailable'].includes(value.state)) {
    throw new Error('invalid freshness state');
  }
  if (typeof value.last_known !== 'boolean') {
    throw new Error('invalid last_known');
  }
  if (value.last_observed_at !== null && !isDateTime(value.last_observed_at)) {
    throw new Error('invalid last_observed_at');
  }
  if (
    (value.state === 'fresh'
      && (value.last_observed_at === null || value.last_known !== false))
    || (value.state === 'stale'
      && (value.last_observed_at === null || value.last_known !== true))
    || (value.state === 'unavailable'
      && value.last_known !== (value.last_observed_at !== null))
  ) {
    throw new Error('inconsistent freshness state');
  }
  if (Object.hasOwn(value, 'reason_code') && !isReasonCode(value.reason_code)) {
    throw new Error('invalid reason_code');
  }
}

function validateNode(value) {
  assertObject(value, 'node');
  assertKeys(value, ['stable_node_id', 'display_name', 'platform', 'agent_version'], 'node');
  for (const key of ['stable_node_id', 'display_name', 'platform', 'agent_version']) {
    if (typeof value[key] !== 'string' || !value[key]) {
      throw new Error(`invalid node ${key}`);
    }
  }
  if (
    value.stable_node_id.length > 128
    || value.display_name.length > 128
    || value.platform.length > 64
    || value.agent_version.length > 64
    || !/^[A-Za-z0-9._:-]+$/.test(value.stable_node_id)
    || !/^[A-Za-z0-9._-]+$/.test(value.platform)
    || !/^[A-Za-z0-9.+_-]+$/.test(value.agent_version)
  ) {
    throw new Error('invalid node identity');
  }
}

function validateTelemetry(value, freshness) {
  assertObject(value, 'telemetry payload');
  assertKeys(value, [
    'collection_status',
    'windows',
    'active_conversation_count',
    'host_cpu_percent',
    'host_network_receive_bytes_per_second',
    'host_network_transmit_bytes_per_second',
    'host_capability_flags',
  ], 'telemetry payload');
  if (!['available', 'degraded', 'unavailable'].includes(value.collection_status)) {
    throw new Error('invalid collection status');
  }
  assertObject(value.windows, 'windows');
  assertKeys(value.windows, ['one_minute', 'five_minutes'], 'windows');
  validateRateWindow(value.windows.one_minute, 60);
  validateRateWindow(value.windows.five_minutes, 300);
  if (!Array.isArray(value.host_capability_flags)) {
    throw new Error('invalid capability flags');
  }
  if (
    !isNullableNonNegativeInteger(value.active_conversation_count)
    || !isNullableNumberInRange(value.host_cpu_percent, 0, 100)
    || !isNullableNonNegativeNumber(value.host_network_receive_bytes_per_second)
    || !isNullableNonNegativeNumber(value.host_network_transmit_bytes_per_second)
    || new Set(value.host_capability_flags).size !== value.host_capability_flags.length
    || !value.host_capability_flags.every((flag) => (
      typeof flag === 'string' && flag.length <= 64 && /^[a-z][a-z0-9._-]*$/.test(flag)
    ))
  ) {
    throw new Error('invalid telemetry values');
  }
  if (
    freshness.state === 'unavailable'
    && freshness.last_known === false
    && (
      value.collection_status !== 'unavailable'
      || value.windows.one_minute.token_rate_per_second !== null
      || value.windows.one_minute.request_rate_per_minute !== null
      || value.windows.five_minutes.token_rate_per_second !== null
      || value.windows.five_minutes.request_rate_per_minute !== null
      || value.active_conversation_count !== null
      || value.host_cpu_percent !== null
      || value.host_network_receive_bytes_per_second !== null
      || value.host_network_transmit_bytes_per_second !== null
      || value.host_capability_flags.length !== 0
    )
  ) {
    throw new Error('unavailable telemetry must not carry observations');
  }
}

function validateRateWindow(value, seconds) {
  assertObject(value, 'rate window');
  assertKeys(
    value,
    ['window_seconds', 'token_rate_per_second', 'request_rate_per_minute'],
    'rate window',
  );
  if (value.window_seconds !== seconds) {
    throw new Error('invalid window size');
  }
  if (
    !isNullableNonNegativeNumber(value.token_rate_per_second)
    || !isNullableNonNegativeNumber(value.request_rate_per_minute)
  ) {
    throw new Error('invalid rate value');
  }
}

function validateDoctor(value, freshness) {
  assertObject(value, 'doctor payload');
  assertKeys(value, ['doctor_state', 'capability_currentness', 'checks'], 'doctor payload');
  if (!Array.isArray(value.checks)) {
    throw new Error('invalid doctor checks');
  }
  if (
    !['healthy', 'degraded', 'failing', 'unavailable', 'unknown'].includes(value.doctor_state)
    || !['current', 'stale', 'unavailable', 'unknown'].includes(value.capability_currentness)
  ) {
    throw new Error('invalid doctor state');
  }
  for (const check of value.checks) {
    assertObject(check, 'doctor check');
    assertKeys(check, ['check_id', 'state', 'reason_code'], 'doctor check', true);
    if (
      typeof check.check_id !== 'string'
      || check.check_id.length > 64
      || !/^[a-z][a-z0-9._-]*$/.test(check.check_id)
      || !['pass', 'warn', 'fail', 'unavailable', 'unknown'].includes(check.state)
    ) {
      throw new Error('invalid doctor check');
    }
    if (Object.hasOwn(check, 'reason_code') && !isReasonCode(check.reason_code)) {
      throw new Error('invalid doctor reason');
    }
  }
  if (
    freshness.state === 'unavailable'
    && freshness.last_known === false
    && (
      value.doctor_state !== 'unavailable'
      || value.capability_currentness !== 'unavailable'
      || value.checks.length !== 0
    )
  ) {
    throw new Error('unavailable doctor must not carry observations');
  }
}

function containsForbiddenKey(value) {
  if (Array.isArray(value)) {
    return value.some(containsForbiddenKey);
  }
  if (value === null || typeof value !== 'object') {
    return false;
  }
  return Object.entries(value).some(([key, child]) => {
    const normalized = key.toLowerCase();
    return FORBIDDEN_KEY_PARTS.some((part) => normalized.includes(part))
      || FORBIDDEN_AUTHORITY_KEYS.has(normalized)
      || containsForbiddenKey(child);
  });
}

function assertObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new RequestError(`${label} must be an object`);
  }
}

function assertKeys(value, allowed, label, optional = false) {
  const actual = Object.keys(value);
  const unexpected = actual.filter((key) => !allowed.includes(key));
  if (unexpected.length > 0) {
    throw new RequestError(`${label} contains unsupported fields`);
  }
  if (!optional) {
    const missing = allowed.filter((key) => !Object.hasOwn(value, key));
    if (missing.length > 0) {
      throw new RequestError(`${label} is missing required fields`);
    }
  }
}

function assertExactObject(value, keys, expected, label) {
  assertObject(value, label);
  assertKeys(value, keys, label);
  for (const [key, expectedValue] of Object.entries(expected)) {
    if (value[key] !== expectedValue) {
      throw new Error(`${label} mismatch`);
    }
  }
}

function isDateTime(value) {
  return typeof value === 'string'
    && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value)
    && !Number.isNaN(Date.parse(value))
    && new Date(value).toISOString() === value;
}

function isReasonCode(value) {
  return typeof value === 'string' && /^[a-z][a-z0-9_]{0,63}$/.test(value);
}

function isNullableNonNegativeNumber(value) {
  return value === null || (typeof value === 'number' && Number.isFinite(value) && value >= 0);
}

function isNullableNonNegativeInteger(value) {
  return value === null || (Number.isInteger(value) && value >= 0);
}

function isNullableNumberInRange(value, minimum, maximum) {
  return value === null
    || (typeof value === 'number' && Number.isFinite(value) && value >= minimum && value <= maximum);
}

class RequestError extends Error {}

async function main() {
  let input = '';
  for await (const chunk of process.stdin) {
    input += chunk;
  }
  let request;
  try {
    request = JSON.parse(input);
  } catch {
    request = null;
  }
  const response = await handleRequest(request);
  process.stdout.write(`${JSON.stringify(response.payload)}\n`);
  process.exitCode = response.code;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  await main();
}
