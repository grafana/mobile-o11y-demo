import { createHash } from 'node:crypto';

export const PAYLOAD_ITEM_KEYS = [
  'events',
  'measurements',
  'logs',
  'exceptions',
];

export function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

export function countPayloadItems(payload) {
  const counts = Object.fromEntries(
    PAYLOAD_ITEM_KEYS.map((key) => [
      key,
      Array.isArray(payload[key]) ? payload[key].length : 0,
    ]),
  );
  counts.traces = countSpans(payload.traces);
  counts.total = Object.values(counts).reduce((sum, value) => sum + value, 0);
  return counts;
}

export function addCounts(total, next) {
  const result = { ...total };
  for (const [key, value] of Object.entries(next)) {
    result[key] = (result[key] ?? 0) + value;
  }
  return result;
}

export function sanitizePayload(payload) {
  return sanitizeValue(structuredClone(payload), []);
}

export function findSensitiveValues(payload) {
  const findings = [];
  inspectSensitiveValue(payload, [], findings);
  return findings;
}

export function prepareReplayPayloads(payloads, { runId, startTime }) {
  if (!runId) {
    throw new Error('runId is required');
  }

  const cloned = structuredClone(payloads);
  const earliestTimestamp = findEarliestTimestamp(cloned);
  const targetTimestamp = startTime ? Date.parse(startTime) : Date.now();
  if (Number.isNaN(targetTimestamp)) {
    throw new Error(`Invalid start time: ${startTime}`);
  }

  const offsetMs = earliestTimestamp == null ? 0 : targetTimestamp - earliestTimestamp;
  const idMaps = new Map();

  for (const payload of cloned) {
    transformValue(payload, [], { runId, offsetMs, idMaps });
    if (!payload.meta?.session) {
      throw new Error('A Faro session is required for benchmark replay');
    }
    payload.meta.session.attributes ??= {};
    payload.meta.session.attributes.benchmark_run_id = runId;
  }

  return {
    payloads: cloned,
    offsetMs,
    remappedIds: Object.fromEntries(
      [...idMaps.entries()].map(([kind, values]) => [kind, values.size]),
    ),
  };
}

function countSpans(value, key = '') {
  if (value == null || typeof value !== 'object') {
    return 0;
  }
  if (Array.isArray(value)) {
    const current = key === 'spans' ? value.length : 0;
    return current + value.reduce((sum, item) => sum + countSpans(item), 0);
  }
  return Object.entries(value).reduce(
    (sum, [childKey, child]) => sum + countSpans(child, childKey),
    0,
  );
}

function sanitizeValue(value, path) {
  if (Array.isArray(value)) {
    return value.map((item, index) => sanitizeValue(item, [...path, index]));
  }
  if (value == null || typeof value !== 'object') {
    return sanitizeScalar(value, path);
  }

  const otelAttribute = getOtelStringAttribute(value);
  if (otelAttribute) {
    otelAttribute.value.stringValue = sanitizeOtelAttribute(
      otelAttribute.key,
      otelAttribute.value.stringValue,
    );
  }

  for (const [key, child] of Object.entries(value)) {
    const childPath = [...path, key];
    const normalizedPath = childPath.join('.').toLowerCase();
    if (normalizedPath === 'meta.user.id') {
      value[key] = 'benchmark-source-user';
    } else if (normalizedPath === 'meta.user.username') {
      value[key] = 'quickpizza-benchmark';
    } else if (normalizedPath === 'meta.user.email') {
      value[key] = 'benchmark@example.invalid';
    } else if (normalizedPath.startsWith('meta.user.attributes.')) {
      value[key] = 'redacted';
    } else if (normalizedPath === 'meta.app.installationid') {
      value[key] = 'benchmark-source-installation';
    } else if (normalizedPath === 'meta.session.attributes.device_id') {
      value[key] = 'benchmark-source-device';
    } else if (isSensitiveKey(key)) {
      value[key] = '[redacted]';
    } else {
      value[key] = sanitizeValue(child, childPath);
    }
  }
  return value;
}

function sanitizeScalar(value, path) {
  if (typeof value !== 'string') {
    return value;
  }
  if (looksLikeEmail(value) && path.join('.').toLowerCase() !== 'meta.user.email') {
    return 'benchmark@example.invalid';
  }
  return value;
}

function inspectSensitiveValue(value, path, findings) {
  if (Array.isArray(value)) {
    value.forEach((item, index) => inspectSensitiveValue(item, [...path, index], findings));
    return;
  }
  if (value == null || typeof value !== 'object') {
    const key = String(path.at(-1) ?? '');
    const normalizedPath = path.join('.').toLowerCase();
    if (
      typeof value === 'string' &&
      isSensitiveIdentityPath(normalizedPath) &&
      !isSanitizedIdentifier(value)
    ) {
      findings.push(path.join('.'));
    } else if (typeof value === 'string' && value !== '[redacted]' && isSensitiveKey(key)) {
      findings.push(path.join('.'));
    } else if (
      typeof value === 'string' &&
      looksLikeEmail(value) &&
      value !== 'benchmark@example.invalid'
    ) {
      findings.push(path.join('.'));
    }
    return;
  }
  const otelAttribute = getOtelStringAttribute(value);
  if (
    otelAttribute &&
    ((isSensitiveAttributeKey(otelAttribute.key) &&
      !isSanitizedIdentifier(otelAttribute.value.stringValue)) ||
      (looksLikeEmail(otelAttribute.value.stringValue) &&
        otelAttribute.value.stringValue !== 'benchmark@example.invalid'))
  ) {
    findings.push([...path, 'value', 'stringValue'].join('.'));
    return;
  }
  for (const [key, child] of Object.entries(value)) {
    inspectSensitiveValue(child, [...path, key], findings);
  }
}

function isSensitiveKey(key) {
  return /^(authorization|api[_-]?key|password|passwd|cookie|secret|access[_-]?token|refresh[_-]?token)$/i.test(
    key,
  );
}

function looksLikeEmail(value) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function findEarliestTimestamp(payloads) {
  let earliest = null;

  visit(payloads, [], (value, path) => {
    const key = normalizeKey(path.at(-1));
    let timestamp = null;
    if (typeof value === 'string' && key === 'timestamp') {
      const parsed = Date.parse(value);
      timestamp = Number.isNaN(parsed) ? null : parsed;
    } else if (typeof value === 'string' && key.endsWith('timeunixnano')) {
      try {
        timestamp = Number(BigInt(value) / 1_000_000n);
      } catch {
        timestamp = null;
      }
    }
    if (timestamp != null && (earliest == null || timestamp < earliest)) {
      earliest = timestamp;
    }
  });

  return earliest;
}

function transformValue(value, path, context) {
  if (Array.isArray(value)) {
    value.forEach((item, index) => transformValue(item, [...path, index], context));
    return;
  }
  if (value == null || typeof value !== 'object') {
    return;
  }

  const otelAttribute = getOtelStringAttribute(value);
  const otelIdKind = otelAttribute ? attributeIdKind(otelAttribute.key) : null;
  if (otelAttribute && otelIdKind && otelAttribute.value.stringValue !== '') {
    otelAttribute.value.stringValue = remapId(
      otelAttribute.value.stringValue,
      otelIdKind,
      context,
    );
  }

  for (const [key, child] of Object.entries(value)) {
    const childPath = [...path, key];
    if (typeof child === 'string') {
      const normalizedKey = normalizeKey(key);
      if (normalizedKey === 'timestamp') {
        const parsed = Date.parse(child);
        if (!Number.isNaN(parsed)) {
          value[key] = new Date(parsed + context.offsetMs).toISOString();
          continue;
        }
      }
      if (normalizedKey.endsWith('timeunixnano')) {
        try {
          value[key] = (BigInt(child) + BigInt(context.offsetMs) * 1_000_000n).toString();
          continue;
        } catch {
          // Keep malformed trace timestamps unchanged.
        }
      }

      const idKind = correlatedIdKind(childPath);
      if (idKind != null && child !== '') {
        value[key] = remapId(child, idKind, context);
        continue;
      }
    }
    transformValue(child, childPath, context);
  }
}

function correlatedIdKind(path) {
  const key = normalizeKey(path.at(-1));
  const parent = normalizeKey(path.at(-2));
  const directKinds = {
    sessionid: 'session',
    pageid: 'page',
    viewid: 'view',
    traceid: 'trace',
    spanid: 'span',
    parentspanid: 'span',
    actionid: 'action',
    actionparentid: 'action',
    installationid: 'installation',
    deviceid: 'device',
    userid: 'user',
  };
  if (directKinds[key]) {
    return directKinds[key];
  }
  if (key === 'parentid' && parent === 'action') {
    return 'action';
  }
  if (key === 'id' && ['session', 'page', 'view', 'action', 'user'].includes(parent)) {
    return parent;
  }
  return null;
}

function attributeIdKind(key) {
  const normalizedKey = normalizeKey(key);
  const kinds = {
    actionid: 'action',
    appinstallationid: 'installation',
    deviceid: 'device',
    faroactionuserid: 'action',
    faroactionuserparentid: 'action',
    installationid: 'installation',
    pageid: 'page',
    parentspanid: 'span',
    sessionid: 'session',
    spanid: 'span',
    traceid: 'trace',
    userid: 'user',
    viewid: 'view',
  };
  return kinds[normalizedKey] ?? null;
}

function getOtelStringAttribute(value) {
  if (
    typeof value?.key === 'string' &&
    value.value != null &&
    typeof value.value === 'object' &&
    typeof value.value.stringValue === 'string'
  ) {
    return value;
  }
  return null;
}

function sanitizeOtelAttribute(key, value) {
  const normalizedKey = normalizeKey(key);
  if (normalizedKey === 'userid') {
    return 'benchmark-source-user';
  }
  if (['useremail', 'email'].includes(normalizedKey)) {
    return 'benchmark@example.invalid';
  }
  if (['username', 'userusername'].includes(normalizedKey)) {
    return 'quickpizza-benchmark';
  }
  if (normalizedKey === 'deviceid') {
    return 'benchmark-source-device';
  }
  if (['appinstallationid', 'installationid'].includes(normalizedKey)) {
    return 'benchmark-source-installation';
  }
  if (isSensitiveAttributeKey(key)) {
    return '[redacted]';
  }
  return looksLikeEmail(value) ? 'benchmark@example.invalid' : value;
}

function isSensitiveAttributeKey(key) {
  if (
    [
      'appinstallationid',
      'deviceid',
      'email',
      'installationid',
      'useremail',
      'userid',
      'username',
      'userusername',
    ].includes(normalizeKey(key))
  ) {
    return true;
  }
  const finalSegment = String(key).split(/[._-]/).at(-1) ?? '';
  return isSensitiveKey(finalSegment);
}

function isSensitiveIdentityPath(path) {
  return [
    'meta.app.installationid',
    'meta.session.attributes.device_id',
    'meta.user.email',
    'meta.user.id',
    'meta.user.username',
  ].includes(path);
}

function isSanitizedIdentifier(value) {
  return [
    '[redacted]',
    'benchmark-source-device',
    'benchmark-source-installation',
    'benchmark-source-user',
    'benchmark@example.invalid',
    'quickpizza-benchmark',
    'redacted',
  ].includes(value);
}

function remapId(value, kind, context) {
  let values = context.idMaps.get(kind);
  if (!values) {
    values = new Map();
    context.idMaps.set(kind, values);
  }
  if (!values.has(value)) {
    const digest = sha256(`${context.runId}:${kind}:${value}`);
    const replacement = /^[0-9a-f]+$/i.test(value)
      ? digest.slice(0, value.length)
      : `${kind}-${digest.slice(0, 16)}`;
    values.set(value, replacement);
  }
  return values.get(value);
}

function normalizeKey(value) {
  return String(value ?? '')
    .replaceAll(/[._-]/g, '')
    .toLowerCase();
}

function visit(value, path, visitor) {
  if (Array.isArray(value)) {
    value.forEach((item, index) => visit(item, [...path, index], visitor));
    return;
  }
  if (value == null || typeof value !== 'object') {
    visitor(value, path);
    return;
  }
  for (const [key, child] of Object.entries(value)) {
    visit(child, [...path, key], visitor);
  }
}
