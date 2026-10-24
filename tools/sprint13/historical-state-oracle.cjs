'use strict';
// Independent, read-only acceptance oracle. Nothing is executed when required.
// This does NOT call migration/normalization code, connect to PostgreSQL, or write files.
// JSON-number comparisons are exact decimal comparisons, not IEEE754 comparisons.
const fs = require('node:fs');
const readline = require('node:readline');
const crypto = require('node:crypto');
const LEGACY_SHA = '79AE70BEC3E552C38B79C1B28E05AA1C4C785B4AE3B0475F70BEC1281CE0256D';
const SEQUENCE_SHA = '931E8CA916B849DF00377FF481B22F05C1A5AD135DCA0313203D5CA6B64B0232';
const LEGACY_BYTES = 307160864;
const MAX_LINE_BYTES = 512 * 1024 * 1024;
function requireThat(value, code) { if (!value) throw new Error(code); }
class Decimal {
  constructor(raw) {
    const m = /^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$/.exec(raw);
    requireThat(m && (!m[4] || m[4].replace(/^[+-]/, '').length <= 6), 'json_number');
    let digits = (m[2] + (m[3] || '')).replace(/^0+/, '');
    let exponent = BigInt(m[4] || '0') - BigInt((m[3] || '').length);
    while (digits.endsWith('0') && digits.length) { digits = digits.slice(0, -1); exponent++; }
    this.normalized = digits ? `${m[1]}${digits}e${exponent}` : '0e0';
    this.raw = raw;
  }
}
// A small JSON parser rejects duplicate keys and retains every numeric token.
// It materializes at most one input line/project, never all heavy project values.
function parseExact(text) {
  let i = text.charCodeAt(0) === 0xfeff ? 1 : 0;
  function ws() { while (i < text.length && /[\x20\x09\x0a\x0d]/.test(text[i])) i++; }
  function string() {
    const start = i++; let closed = false;
    while (i < text.length) {
      const ch = text[i++];
      if (ch === '\\') { i++; continue; }
      if (ch === '"') { closed = true; break; }
    }
    requireThat(closed, 'json_string');
    const value = JSON.parse(text.slice(start, i));
    requireThat(typeof value === 'string' && value.isWellFormed(), 'json_unicode');
    return value;
  }
  function value(depth) {
    requireThat(depth <= 256, 'json_depth'); ws(); const ch = text[i];
    if (ch === '"') return string();
    if (ch === '{') {
      i++; ws(); const result = Object.create(null);
      if (text[i] === '}') { i++; return result; }
      for (;;) {
        ws(); requireThat(text[i] === '"', 'json_object_key'); const key = string();
        requireThat(!Object.hasOwn(result, key), 'json_duplicate_key'); ws();
        requireThat(text[i++] === ':', 'json_colon'); result[key] = value(depth + 1); ws();
        const next = text[i++]; if (next === '}') return result;
        requireThat(next === ',', 'json_object_separator');
      }
    }
    if (ch === '[') {
      i++; ws(); const result = [];
      if (text[i] === ']') { i++; return result; }
      for (;;) {
        result.push(value(depth + 1)); ws(); const next = text[i++];
        if (next === ']') return result; requireThat(next === ',', 'json_array_separator');
      }
    }
    for (const [literal, result] of [['true', true], ['false', false], ['null', null]]) {
      if (text.startsWith(literal, i)) { i += literal.length; return result; }
    }
    const m = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(text.slice(i));
    requireThat(m, 'json_value'); i += m[0].length; return new Decimal(m[0]);
  }
  const result = value(0); ws(); requireThat(i === text.length, 'json_trailing_bytes'); return result;
}
function exactInteger(value) {
  if (typeof value === 'string') { requireThat(/^-?(0|[1-9][0-9]*)$/.test(value), 'integer_string'); return value; }
  requireThat(value instanceof Decimal && /^-?(0|[1-9][0-9]*)$/.test(value.raw), 'integer_exact');
  return value.raw;
}
function sortedKeys(value) { return Object.keys(value).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b))); }
function valueDigest(value) {
  const hash = crypto.createHash('sha256');
  function frame(tag, data) { const b = Buffer.from(data); hash.update(tag + b.length + ':'); hash.update(b); }
  function walk(v) {
    if (v instanceof Decimal) return frame('N', v.normalized);
    if (v === null) return hash.update('Z');
    if (typeof v === 'string') return frame('S', v);
    if (typeof v === 'boolean') return hash.update(v ? 'T' : 'F');
    requireThat(typeof v === 'object', 'unexpected_json_type');
    if (Array.isArray(v)) { hash.update('A' + v.length + ':'); for (const x of v) walk(x); return; }
    const keys = sortedKeys(v); hash.update('O' + keys.length + ':');
    for (const key of keys) { frame('K', key); walk(v[key]); }
  }
  walk(value); return hash.digest('hex').toUpperCase();
}
async function fileHash(path) {
  const h = crypto.createHash('sha256'); let bytes = 0;
  for await (const chunk of fs.createReadStream(path)) { h.update(chunk); bytes += chunk.length; }
  return { sha256: h.digest('hex').toUpperCase(), bytes };
}
async function eachLine(path, fn) {
  const lines = readline.createInterface({ input: fs.createReadStream(path), crlfDelay: Infinity });
  let count = 0;
  for await (const line of lines) {
    requireThat(Buffer.byteLength(line) <= MAX_LINE_BYTES && line.trim().length > 0, 'capture_line_bounds');
    await fn(parseExact(line), ++count);
  }
  return count;
}
function id(parts) { return JSON.stringify(parts); }
function insert(map, identity, digest) {
  requireThat(!map.has(identity), 'duplicate_capture_identity'); map.set(identity, digest);
}
function knownKeys(object, allowed, code) {
  requireThat(object && typeof object === 'object' && !Array.isArray(object), code);
  requireThat(Object.keys(object).every(k => allowed.includes(k)), code);
}
const REPO_KEYS = ['organization', 'audit', 'logs', 'current', 'sequence', 'user_views', 'models', 'durable_jobs'];
const LOG_STATE_KEYS = ['id', 'filename', 'analysis_version', 'view_revision', 'threshold', 'selected', 'selected_case', 'elapsed_ms', 'source_sha256', 'order', 'filters', 'calendar', 'project_id'];
function projectExpectations(project, repo, version, map) {
  knownKeys(repo, REPO_KEYS, 'unsupported_repository_field');
  for (const key of ['logs', 'current', 'sequence', 'user_views', 'models', 'durable_jobs']) requireThat(Object.hasOwn(repo, key), 'missing_repository_field');
  const header = { current: repo.current, sequence: repo.sequence, user_views: repo.user_views, durable_jobs: repo.durable_jobs,
    log_ids: sortedKeys(repo.logs), model_ids: sortedKeys(repo.models) };
  for (const key of ['organization', 'audit']) if (Object.hasOwn(repo, key)) header[key] = repo[key];
  insert(map, id(['project', project, version]), valueDigest(header));
  let logs = 0, records = 0;
  for (const logId of sortedKeys(repo.logs)) {
    const log = repo.logs[logId];
    knownKeys(log, [...LOG_STATE_KEYS, 'created_at', 'data', 'source', 'analysis', 'provenance'], 'unsupported_log_field');
    requireThat(log.id === logId && log.project_id === project, 'log_identity');
    const state = Object.create(null);
    for (const key of LOG_STATE_KEYS) { requireThat(Object.hasOwn(log, key), 'missing_log_state_field'); state[key] = log[key]; }
    if (Object.hasOwn(log, 'created_at')) { requireThat(typeof log.created_at === 'string', 'log_created_at'); state.created_at = log.created_at; }
    const source = Object.hasOwn(log, 'provenance') ? { source_envelope_version: new Decimal('1'), source: log.source, provenance: log.provenance } : log.source;
    for (const [kind, body] of [['log_state', state], ['log_data', log.data], ['log_source', source], ['log_analysis', log.analysis]]) {
      requireThat(body !== undefined, 'missing_log_payload'); insert(map, id(['record', project, kind, logId, '1']), valueDigest(body)); records++;
    }
    logs++;
  }
  for (const modelId of sortedKeys(repo.models)) {
    const model = repo.models[modelId]; requireThat(model.id === modelId, 'model_identity');
    insert(map, id(['record', project, 'model', modelId, '1']), valueDigest(model)); records++;
  }
  return { logs, models: Object.keys(repo.models).length, records };
}

// Ledger applied_at is PostgreSQL timestamptz, not a JSON document field.
// Historical capture used +05:00; maintained capture explicitly uses UTC.
// Derive expected UTC timestamp ONLY from OLD schema ledger version1.
// Actual capture stays strictly compared as-is; equal mode has no normalization.
// No Date millisecond truncation, repository/Auth string rewrite or POST oracle.
function ledgerExpectedUTC(row) {
  if (exactInteger(row.version) !== '1') return row;
  requireThat(typeof row.applied_at === 'string', 'ledger1_timestamp_type');
  const m = /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|([+-])(\d{2}):(\d{2}))$/.exec(row.applied_at);
  requireThat(m && Number(m[2]) < 24 && Number(m[3]) < 60 && Number(m[4]) < 60 && (!m[8] || Number(m[8]) < 16) && (!m[9] || Number(m[9]) < 60), 'ledger1_timestamp_shape');
  const local = `${m[1]}T${m[2]}:${m[3]}:${m[4]}Z`, ms = Date.parse(local);
  requireThat(Number.isFinite(ms) && new Date(ms).toISOString().slice(0,19) === local.slice(0,19), 'ledger1_timestamp_calendar');
  const offsetMinutes = m[6] === 'Z' ? 0 : (Number(m[8]) * 60 + Number(m[9])) * (m[7] === '-' ? -1 : 1);
  const fraction = (m[5] || '').replace(/0+$/, '');
  const utcSeconds = new Date(ms - offsetMinutes * 60000).toISOString().slice(0,19);
  return { ...row, applied_at: `${utcSeconds}${fraction ? '.' + fraction : ''}+00:00` };
}

async function legacyExpectations(path, mode) {
  const binding = await fileHash(path);
  requireThat(binding.sha256 === LEGACY_SHA && binding.bytes === LEGACY_BYTES, 'full_original_fixture_binding');
  const map = new Map(); const projects = []; const ledger = []; let kvCount = 0;
  const counts = { logs: 0, models: 0, records: 0 };
  await eachLine(path, row => {
    if (row.kind === 'ledger') { ledger.push(row.row); insert(map, id(['ledger', exactInteger(row.row.version)]), valueDigest(ledgerExpectedUTC(row.row))); return; }
    requireThat(row.kind === 'kv' && typeof row.key === 'string', 'unexpected_legacy_row');
    const version = exactInteger(row.version); requireThat(BigInt(version) > 0n, 'legacy_version');
    insert(map, id(['kv', row.key, version]), valueDigest(row.document)); kvCount++;
    if (row.key.startsWith('repository/')) {
      const project = row.key.slice('repository/'.length); requireThat(project.length > 0, 'legacy_project');
      projects.push({ project, version });
      if (mode === 'forward' || mode === 'partial') {
        const c = projectExpectations(project, row.document, version, map);
        for (const k of Object.keys(counts)) counts[k] += c[k];
      }
    }
  });
  requireThat(kvCount === 12 && projects.length === 10 && ledger.length === 1 && exactInteger(ledger[0].version) === '1', 'unreduced_historical_counts');
  return { map, projects, counts, binding };
}
function captureEntry(row) {
  requireThat(Array.isArray(row), 'capture_array_required');
  if (row[0] === 'kv' || row[0] === 'project') {
    requireThat(row.length === 4 && typeof row[1] === 'string' && typeof row[2] === 'string', 'capture_version_decimalstring');
    return [id([row[0], row[1], exactInteger(row[2])]), valueDigest(row[3])];
  }
  if (row[0] === 'record') {
    requireThat(row.length === 6 && row.slice(1, 5).every(x => typeof x === 'string'), 'record_shape');
    return [id(['record', row[1], row[2], row[3], exactInteger(row[4])]), valueDigest(row[5])];
  }
  if (row[0] === 'marker') {
    requireThat(row.length === 2 && typeof row[1].project_id === 'string', 'marker_shape');
    return [id(['marker', row[1].project_id]), valueDigest(row[1])];
  }
  if (row[0] === 'ledger') { requireThat(row.length === 2, 'ledger_shape'); return [id(['ledger', exactInteger(row[1].version)]), valueDigest(row[1])]; }
  if (row[0] === 'sequence') {
    requireThat(row.length === 4 && typeof row[1] === 'string' && typeof row[2] === 'string' && typeof row[3] === 'boolean', 'sequence_exact_strings');
    exactInteger(row[1]); exactInteger(row[2]); return [id(['sequence']), valueDigest(row.slice(1))];
  }
  if (row[0] === 'sequence_definition') {
    requireThat(row.length === 8 && row.slice(1, 7).every(x => typeof x === 'string') && typeof row[7] === 'boolean', 'sequence_definition_exact_strings');
    for (const x of row.slice(1, 7)) exactInteger(x);
    return [id(['sequence_definition']), valueDigest(row.slice(1))];
  }
  throw new Error('unknown_capture_tag');
}
async function sequenceExpectations(path, map) {
  requireThat((await fileHash(path)).sha256 === SEQUENCE_SHA, 'historical_exact_sequence_binding');
  const s = parseExact(fs.readFileSync(path, 'utf8'));
  requireThat(s.state.length === 3 && s.state[0] === '63' && s.state[1] === '0' && s.state[2] === true, 'historical_sequence');
  insert(map, id(['sequence']), valueDigest(s.state));
  const d = s.definition;
  insert(map, id(['sequence_definition']), valueDigest([d.seqtypid, d.seqstart, d.seqincrement, d.seqmax, d.seqmin, d.seqcache, d.seqcycle]));
}
async function compareExpected(path, expected, opts) {
  const seen = new Set(); let count = 0, ledger2 = false;
  const captureBinding = await fileHash(path);
  await eachLine(path, row => {
    const [key, digest] = captureEntry(row); requireThat(!seen.has(key), 'duplicate_actual_identity'); seen.add(key); count++;
    if (opts.mode === 'partial' && row[0] === 'ledger') requireThat(exactInteger(row[1].version) !== '2', 'partial_must_not_publish_ledger2');
    if (opts.mode === 'forward' && row[0] === 'ledger' && exactInteger(row[1].version) === '2') {
      requireThat(!ledger2, 'duplicate_ledger2'); ledger2 = true;
      const l = row[1]; knownKeys(l, ['version', 'name', 'checksum', 'applied_at'], 'ledger2_fields');
      requireThat(Object.keys(l).length === 4 && l.name === 'normalized_v2' && l.checksum === opts.checksum, 'ledger2_binding');
      requireThat(typeof l.applied_at === 'string' && Number.isFinite(Date.parse(l.applied_at)), 'ledger2_timestamp');
      requireThat(Date.parse(l.applied_at) >= opts.notBefore && Date.parse(l.applied_at) <= opts.notAfter, 'ledger2_time_bounds'); return;
    }
    requireThat(expected.has(key) && expected.get(key) === digest, 'whole_expected_state_mismatch');
  });
  if (opts.mode === 'partial') {
    let baseline = 0, records = 0;
    for (const key of expected.keys()) {
      const identity = JSON.parse(key);
      if (['kv', 'ledger', 'sequence', 'sequence_definition'].includes(identity[0])) {
        requireThat(seen.has(key), 'partial_missing_original_baseline'); baseline++;
      }
    }
    requireThat(seen.size > baseline && seen.size < expected.size, 'partial_nonempty_strict_subset');
    const versions = new Map();
    for (const key of expected.keys()) { const identity = JSON.parse(key); if (identity[0] === 'project') versions.set(identity[1], identity[2]); }
    for (const key of seen) {
      const identity = JSON.parse(key);
      if (['project', 'marker', 'record'].includes(identity[0])) {
        const project = identity[1];
        requireThat(versions.has(project) && seen.has(id(['project', project, versions.get(project)]))
          && seen.has(id(['marker', project])), 'partial_header_marker_dependency');
      }
      if (identity[0] === 'record') records++;
    }
    requireThat(records > 0, 'partial_requires_committed_record_progress');
    return { rows: count, original_baseline_rows: baseline, committed_records_observed: records,
      missing_expected_normalized_rows: expected.size - seen.size, ...captureBinding };
  }
  requireThat(seen.size === expected.size + (opts.mode === 'forward' ? 1 : 0), 'whole_keyset_count');
  for (const key of expected.keys()) requireThat(seen.has(key), 'missing_expected_identity');
  if (opts.mode === 'forward') requireThat(ledger2, 'ledger2_missing');
  return { rows: count, ...captureBinding };
}
async function run(opts) {
  requireThat(['original', 'forward', 'partial', 'equal'].includes(opts.mode), 'mode');
  if (opts.mode === 'equal') {
    const expected = new Map();
    await eachLine(opts.before, row => { const [k, d] = captureEntry(row); insert(expected, k, d); });
    requireThat(expected.has(id(['sequence'])) && expected.has(id(['sequence_definition'])), 'complete_sequence_required');
    const compared = await compareExpected(opts.after, expected, opts);
    return { status: 'WHOLE_TYPED_CAPTURE_EQUAL', expected_rows: expected.size, before: await fileHash(opts.before), after: compared, limits: ['Exact sequence tuple including log_cnt; no restore/crash tolerance silently applied', 'No catalog/physical identity inference from managed rows'] };
  }
  const e = await legacyExpectations(opts.legacyValues, opts.mode); await sequenceExpectations(opts.sequence, e.map);
  let sourceHashBinding = null;
  if (opts.mode === 'forward' || opts.mode === 'partial') {
    requireThat(/^[A-Fa-f0-9]{64}$/.test(opts.checksum || ''), 'required_normalized_ddl_checksum');
    if (opts.mode === 'forward') requireThat(Number.isFinite(opts.notBefore) && Number.isFinite(opts.notAfter) && opts.notBefore <= opts.notAfter, 'required_ledger_time_bounds');
    requireThat(opts.sourceHashes && /^[A-Fa-f0-9]{64}$/.test(opts.sourceHashesSha || ''), 'required_independent_rust_source_hash_fixture');
    sourceHashBinding = await fileHash(opts.sourceHashes); requireThat(sourceHashBinding.sha256 === opts.sourceHashesSha.toUpperCase(), 'source_hash_fixture_sha');
    const fixture = parseExact(fs.readFileSync(opts.sourceHashes, 'utf8'));
    knownKeys(fixture, ['status', 'input_sha256', 'rows'], 'source_hash_fixture_fields');
    requireThat(fixture.status === 'PURE_RUST_VALUE_HASH_CALIBRATION_NOT_MIGRATION_ACCEPTANCE'
      && fixture.input_sha256.toUpperCase() === LEGACY_SHA && Array.isArray(fixture.rows) && fixture.rows.length === 12, 'source_hash_original_binding');
    const hashes = new Map();
    const sourceKeys = new Set();
    for (const h of fixture.rows) {
      knownKeys(h, ['key', 'version', 'rust_value_sha256'], 'source_hash_project_fields');
      requireThat(typeof h.key === 'string' && !sourceKeys.has(h.key) && /^[0-9a-f]{64}$/.test(h.rust_value_sha256), 'source_hash_project_binding');
      sourceKeys.add(h.key); const version = exactInteger(h.version);
      requireThat(e.map.has(id(['kv', h.key, version])), 'source_hash_full_keyset_version');
      if (h.key.startsWith('repository/')) hashes.set(h.key.slice('repository/'.length), { version, digest: h.rust_value_sha256 });
    }
    requireThat(hashes.size === 10, 'source_hash_project_count');
    for (const { project, version } of e.projects) {
      const h = hashes.get(project); requireThat(h && h.version === version, 'source_hash_project_version');
      const marker = { project_id: project, source_version: new Decimal(version), source_sha: h.digest, checksum: opts.checksum.toLowerCase() };
      insert(e.map, id(['marker', project]), valueDigest(marker));
    }
  }
  const compared = await compareExpected(opts.capture, e.map, opts);
  return { status: opts.mode === 'forward' ? 'FULL_HISTORICAL_FORWARD_EXPECTED_STATE_MATCHED'
      : opts.mode === 'partial' ? 'PARTIAL_COMMITTED_PROGRESS_STRICT_SUBSET_ONLY_NOT_FULL_FORWARD' : 'FULL_ORIGINAL_TYPED_STATE_MATCHED',
    legacy_binding: e.binding, projects: e.projects.length, expected_records: e.counts.records, logs: e.counts.logs, models: e.counts.models,
    capture: compared, source_hash_fixture: sourceHashBinding,
    limits: ['Independent complete field/value projection; does not invoke production normalization', 'Partial mode requires original baseline exact, no ledger2, nonempty strict subset with at least one committed record and header/marker dependencies; partial is NEVER full migration acceptance', 'Source SHA is a REQUIRED separately frozen RustValue-serializer primitive fixture, never inferred from tested POST or SQLJSONB/Python/JS bytes', 'Length-framed canonical exact-decimal value hashes are comparison-domain only, NOT Rust source_sha or PostgreSQL text SHA', 'Original Auth/generic/retained legacy/ledger1 preserved exactly; no login/normalization/session delta allowed in this phase', 'Exact sequence last_value/log_cnt/is_called and typed definition; physical seqrelid excluded explicitly', 'No full catalog/schema, runtime startup/RBAC, fault phase, physical cluster or byte-identical original JSON formatting inference', 'Only one heavy input line/project materialized; line512MiB/depth256 bounds, not constant-memory token streaming within a project'] };
}
function argumentsOf(argv) {
  const allowed = new Set(['mode', 'legacy-values', 'capture', 'sequence', 'source-hashes', 'source-hashes-sha', 'checksum', 'not-before', 'not-after', 'before', 'after']);
  const result = Object.create(null);
  for (let i = 0; i < argv.length; i += 2) {
    requireThat(argv[i].startsWith('--') && i + 1 < argv.length, 'arguments'); const key = argv[i].slice(2);
    requireThat(allowed.has(key) && !Object.hasOwn(result, key), 'unknown_or_duplicate_argument'); result[key] = argv[i + 1];
  }
  return { mode: result.mode, legacyValues: result['legacy-values'], capture: result.capture, sequence: result.sequence,
    sourceHashes: result['source-hashes'], sourceHashesSha: result['source-hashes-sha'], checksum: result.checksum,
    notBefore: Date.parse(result['not-before']), notAfter: Date.parse(result['not-after']), before: result.before, after: result.after };
}
module.exports = { Decimal, parseExact, exactInteger, valueDigest, projectExpectations, captureEntry, ledgerExpectedUTC, run, argumentsOf };
if (require.main === module) run(argumentsOf(process.argv.slice(2))).then(result => {
  process.stdout.write(JSON.stringify({ ...result, utc: new Date().toISOString() }) + '\n');
}).catch(error => {
  // Fixed safe codes only: never include private keys, payloads, paths or assertion diffs.
  const safe = /^[a-z0-9_]+$/.test(error.message || '') ? error.message : 'oracle_io_or_parse_failure';
  process.stderr.write(JSON.stringify({ status: 'FAIL', code: safe }) + '\n'); process.exitCode = 1;
});
