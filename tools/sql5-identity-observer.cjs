'use strict';
// Draft, inert until explicitly launched by the reviewed owned-resource runner.
// No children, SQL generation, credentials, configuration writes or SQL replacement.
const net = require('node:net');
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const utf8 = new TextDecoder('utf-8', {fatal: true});
const IDENTITY = "SELECT (pg_control_system()).system_identifier::text, d.oid::text, current_database(), current_setting('server_version_num'), current_setting('server_encoding'), pg_is_in_recovery(), current_setting('transaction_read_only') FROM pg_database d WHERE d.datname=current_database()";
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const MAX_FRAME = 1024 * 1024, MAX_QUEUE = 2 * MAX_FRAME, HOLD_MS = 6500;
const cfg = {
  database: process.env.PI_OBSERVER_DATABASE,
  optionsSha: process.env.PI_OBSERVER_OPTIONS_SHA,
  listen: Number(process.env.PI_OBSERVER_LISTEN_PORT),
  evidence: process.env.PI_OBSERVER_EVIDENCE,
  mode: process.env.PI_OBSERVER_MODE
};
if (!cfg.database || !/^[a-z][a-z0-9_]{1,62}$/.test(cfg.database) ||
    !/^[a-f0-9]{64}$/.test(cfg.optionsSha || '') ||
    !Number.isInteger(cfg.listen) || cfg.listen < 1024 || cfg.listen > 65535 || cfg.listen === 5463 ||
    !['observe','hold'].includes(cfg.mode) || !cfg.evidence || !path.isAbsolute(cfg.evidence)) {
  throw new Error('observer_arguments_stop');
}
// Runner owns canonical/no-reparse/private-ACL directory admission before launch.
const fd = fs.openSync(cfg.evidence, 'wx', 0o600);
const begin = process.hrtime.bigint();
let sequence = 0, closed = false, accepted = false, client, backend, timer, watchdog;
let targetStatement, targetPortal, parseComplete = false, bound = false, bindComplete = false;
let heldExecute, heldSync, released = false, holdStarted = false, backendPid;
let bindForwardedAt, target57014 = false, terminateForwarded = false, startupReady = false;
let closeRequested = false, closeComplete = false;
let executeSeen = false, identityRows = 0, commandComplete = false, postExecuteReady = false;
function evidence(event, extra = {}) {
  if (closed) return;
  fs.writeSync(fd, JSON.stringify({sequence: ++sequence, utc: new Date().toISOString(),
    elapsed_ms: Number(process.hrtime.bigint() - begin) / 1e6, event, ...extra}) + '\n');
}
function close(reason, code = 2) {
  if (closed) return;
  evidence('stop', {reason, target_bound: bound, bind_complete: bindComplete,
    execute_held: !!heldExecute, sync_held: !!heldSync, released,
    bind_forwarded: bindForwardedAt !== undefined, actual_target_57014: target57014,
    actual_terminate_forwarded: terminateForwarded, identity_rows: identityRows,
    actual_command_complete: commandComplete, actual_post_execute_ready: postExecuteReady});
  closed = true; clearTimeout(timer); clearTimeout(watchdog);
  if (client) client.destroy(); if (backend) backend.destroy();
  server.close(); fs.fsyncSync(fd); fs.closeSync(fd); process.exitCode = code;
}
function stringAt(buf, offset) {
  const end = buf.indexOf(0, offset);
  if (end < 0) throw new Error('cstring_stop');
  return {value: utf8.decode(buf.subarray(offset, end)), next: end + 1};
}
function send(socket, frame, flushed) {
  if (closed) return;
  // No unbounded write queue: inability to drain within this diagnostic is STOP.
  if (socket.writableLength + frame.length > MAX_QUEUE) return close('write_queue_stop');
  socket.write(frame, () => {if (!closed && flushed) flushed();});
}
function scheduleHold() {
  if (cfg.mode !== 'hold' || holdStarted || bindForwardedAt === undefined || !heldExecute || !heldSync) return;
  const elapsed = Number(process.hrtime.bigint() - bindForwardedAt) / 1e6;
  if (elapsed > 250) return close('original_cycle_capture_late_stop');
  holdStarted = true;
  evidence('hold_started', {hold_ms_from_bind_write_callback: HOLD_MS, capture_elapsed_ms: elapsed,
    actual_bind_complete_already_seen: bindComplete, execute_sha: sha(heldExecute), sync_sha: sha(heldSync), backend_pid: backendPid});
  timer = setTimeout(() => {
    if (closed) return;
    released = true;
    evidence('held_original_frames_released', {execute_sha: sha(heldExecute), sync_sha: sha(heldSync)});
    send(backend, heldExecute); send(backend, heldSync);
  }, Math.max(1, HOLD_MS - elapsed));
}
function frontend(frame) {
  const type = String.fromCharCode(frame[0]), body = frame.subarray(5);
  if (type === 'X') {
    if (body.length) return close('terminate_shape_stop');
    if (heldExecute && !released && !target57014) return close('terminate_during_unproven_hold_stop');
    evidence(target57014 ? 'known_post57014_original_terminate' : 'actual_original_terminate',
      {frame_sha: sha(frame), held_pair_not_released: !!heldExecute && !released, bind_complete: bindComplete});
    if (target57014) clearTimeout(timer);
    send(backend, frame, () => {
      terminateForwarded = true;
      evidence('actual_original_terminate_forwarded');
      if (target57014) close('known_post57014_terminate', 0);
    });
    return;
  }
  if (type === 'C') {
    if (!body.length || closeRequested) return close('close_shape_or_duplicate_stop');
    const kind = String.fromCharCode(body[0]), name = stringAt(body, 1);
    if (name.next !== body.length || !bound || !((kind === 'S' && name.value === targetStatement) ||
        (kind === 'P' && name.value === targetPortal)) || (heldExecute && !released && !target57014)) {
      return close('close_identity_phase_stop');
    }
    closeRequested = true;
    evidence('actual_original_target_close', {frame_sha: sha(frame), kind, after_target_57014: target57014});
    send(backend, frame); return;
  }
  if (heldExecute && !released && type !== 'S') return close('unknown_held_phase_stop');
  if (type === 'P') {
    if (cfg.mode === 'observe' && identityRows === 1 && commandComplete && postExecuteReady) return close('identity_observe_complete_before_additional_parse', 0);
    if (!startupReady || targetStatement !== undefined) return close('additional_or_early_parse_stop');
    const stmt = stringAt(body, 0), sql = stringAt(body, stmt.next);
    if (sql.value !== IDENTITY || sql.next + 2 !== body.length || body.readUInt16BE(sql.next) !== 0) {
      return close('unexpected_first_parse_stop');
    }
    targetStatement = stmt.value;
    evidence('actual_identity_parse', {sql_sha: sha(Buffer.from(sql.value)), frame_sha: sha(frame), parameter_types: 0});
  } else if (type === 'B') {
    const portal = stringAt(body, 0), stmt = stringAt(body, portal.next);
    if (targetStatement === undefined || stmt.value !== targetStatement || bound || !parseComplete) return close('unexpected_bind_stop');
    let offset = stmt.next;
    if (offset + 2 > body.length) return close('bind_shape_stop');
    const formats = body.readUInt16BE(offset); offset += 2;
    for (let i = 0; i < formats; i++, offset += 2) {
      if (offset + 2 > body.length || body.readUInt16BE(offset) > 1) return close('bind_format_code_stop');
    }
    if (formats > 1 || offset + 2 > body.length || body.readUInt16BE(offset) !== 0) return close('identity_bind_parameters_stop');
    offset += 2;
    if (offset + 2 > body.length) return close('bind_shape_stop');
    const results = body.readUInt16BE(offset); offset += 2;
    for (let i = 0; i < results; i++, offset += 2) {
      if (offset + 2 > body.length || body.readUInt16BE(offset) > 1) return close('bind_result_code_stop');
    }
    if (results > 7 || offset !== body.length) return close('bind_shape_stop');
    bound = true; targetPortal = portal.value;
    evidence('actual_identity_bind', {frame_sha: sha(frame), parameter_values: 0, result_formats: results});
    send(backend, frame, () => {
      bindForwardedAt = process.hrtime.bigint();
      evidence('actual_original_bind_write_complete', {frame_sha: sha(frame)});
      scheduleHold();
    });
    return;
  } else if (type === 'E') {
    const portal = stringAt(body, 0);
    if (!bound || portal.value !== targetPortal || portal.next + 4 !== body.length || body.readUInt32BE(portal.next) !== 0 || heldExecute) return close('unexpected_execute_stop');
    evidence('actual_original_execute', {frame_sha: sha(frame), max_rows: 0});
    executeSeen = true;
    if (cfg.mode === 'hold') {heldExecute = Buffer.from(frame); scheduleHold(); return;}
  } else if (type === 'S') {
    if (body.length !== 0) return close('sync_shape_stop');
    if (cfg.mode === 'hold' && heldExecute && !released) {
      if (heldSync) return close('duplicate_held_sync_stop');
      heldSync = Buffer.from(frame); evidence('actual_original_sync_held', {frame_sha: sha(frame)}); scheduleHold(); return;
    }
  } else if (type === 'D') {
    if (!body.length) return close('describe_shape_stop');
    const kind = String.fromCharCode(body[0]), name = stringAt(body, 1);
    if (name.next !== body.length || !((kind === 'S' && targetStatement !== undefined && name.value === targetStatement) ||
        (kind === 'P' && bound && name.value === targetPortal))) return close('describe_identity_stop');
  } else if (type === 'H') {
    if (body.length) return close('flush_shape_stop');
  } else if (type === 'p') {
    if (startupReady) return close('authentication_after_startup_stop');
  } else if (type === 'Q') return close('simple_query_stop');
  else return close('unknown_frontend_type_stop');
  // Authentication responses are forwarded byte-for-byte but never hashed/logged.
  send(backend, frame);
}
function backendFrame(frame) {
  const type = String.fromCharCode(frame[0]), body = frame.subarray(5);
  if (!['R','S','K','Z','1','2','3','t','T','n','D','C','E','N','A'].includes(type)) return close('unknown_backend_type_stop');
  if (type === 'K') {
    if (body.length !== 8 || backendPid !== undefined) return close('backend_key_shape_stop');
    backendPid = body.readUInt32BE(0); // Cancel key is never recorded.
    evidence('actual_backend_pid', {backend_pid: backendPid});
  } else if (type === '1') {
    if (body.length || targetStatement === undefined || parseComplete) return close('parse_complete_phase_stop');
    parseComplete = true; evidence('actual_parse_complete');
  } else if (type === '2') {
    if (body.length || !bound || bindComplete) return close('bind_complete_phase_stop');
    bindComplete = true; evidence('actual_bind_complete', {backend_pid: backendPid}); scheduleHold();
  } else if (type === '3') {
    if (body.length || !closeRequested || closeComplete) return close('close_complete_phase_stop');
    closeComplete = true; evidence('actual_target_close_complete');
  } else if (type === 'D') {
    if (!executeSeen || !bindComplete || commandComplete || identityRows || body.length < 2 || body.readUInt16BE(0) !== 7) return close('identity_row_phase_shape_stop');
    let offset = 2; const lengths = [];
    for (let i = 0; i < 7; i++) {
      if (offset + 4 > body.length) return close('identity_row_bounds_stop');
      const length = body.readInt32BE(offset); offset += 4;
      if (length < 0 || offset + length > body.length) return close('identity_row_length_stop');
      lengths.push(length); offset += length;
    }
    if (offset !== body.length) return close('identity_row_trailing_stop');
    identityRows = 1; evidence('actual_identity_datarow', {columns: 7, column_lengths: lengths});
  } else if (type === 'C') {
    if (!executeSeen || commandComplete || identityRows !== 1 || !body.equals(Buffer.from('SELECT 1\0'))) return close('identity_command_phase_tag_stop');
    commandComplete = true; evidence('actual_identity_command_complete', {public_tag: 'SELECT 1', rows: 1});
  } else if (type === 'E') {
    let offset = 0, sqlstate, message;
    while (offset < body.length && body[offset]) {
      const code = String.fromCharCode(body[offset++]), field = stringAt(body, offset); offset = field.next;
      if (code === 'C') sqlstate = field.value;
      if (code === 'M') message = field.value;
    }
    if (offset !== body.length-1 || !sqlstate || !/^[0-9A-Z]{5}$/.test(sqlstate)) return close('error_shape_stop');
    if (sqlstate === '57014') {
      if (!bound || !bindComplete || bindForwardedAt === undefined || !heldExecute || !heldSync || !holdStarted || backendPid === undefined) {
        return close('57014_unproven_target_phase_stop');
      }
      if (message !== 'canceling statement due to statement timeout') return close('57014_not_statement_timeout_stop');
      target57014 = true;
    }
    evidence('actual_server_error', {sqlstate, backend_pid: backendPid, statement_timeout_reason_verified: target57014, before_execute_release: !!heldExecute && !released});
  } else if (type === 'Z') {
    if (body.length !== 1 || !['I','T','E'].includes(String.fromCharCode(body[0]))) return close('ready_shape_stop');
    evidence('actual_ready', {transaction_status: String.fromCharCode(body[0])});
    if (executeSeen && commandComplete) {postExecuteReady = true; evidence('actual_identity_post_execute_ready');}
    startupReady = true;
  }
  // Never record Auth/SASL payloads, DataRow/RowDescription, errors' messages/details,
  // notice bodies, parameter values, startup user or cancellation secret.
  send(client, frame);
}
function framed(socket, initial, handler) {
  let pending = Buffer.alloc(0), startup = initial;
  socket.on('data', chunk => {
    if (closed) return;
    try {
      if (pending.length + chunk.length > MAX_QUEUE) return close('read_queue_stop');
      pending = Buffer.concat([pending, chunk]);
      while (!closed) {
        const header = startup ? 4 : 5;
        if (pending.length < header) break;
        const length = pending.readUInt32BE(startup ? 0 : 1), total = startup ? length : length + 1;
        if (length < (startup ? 8 : 4) || total > MAX_FRAME) return close('frame_bound_stop');
        if (pending.length < total) break;
        const frame = pending.subarray(0, total); pending = pending.subarray(total);
        if (startup) {
          if (frame.readUInt32BE(4) !== 196608) return close('non_NoTls_protocol3_stop');
          const values = new Map(); let offset = 8;
          while (offset < frame.length && frame[offset]) {
            const key = stringAt(frame, offset), val = stringAt(frame, key.next); offset = val.next;
            if (values.has(key.value)) return close('duplicate_startup_key_stop');
            values.set(key.value, val.value);
          }
          if (offset !== frame.length - 1 || values.get('database') !== cfg.database ||
              sha(Buffer.from(values.get('options') || '')) !== cfg.optionsSha ||
              values.get('application_name') !== 'pi_cleanup_offline') return close('startup_identity_options_stop');
          evidence('actual_startup_admitted', {database_sha: sha(Buffer.from(cfg.database)), options_sha: cfg.optionsSha, protocol: 196608});
          startup = false; send(backend, frame);
        } else handler(frame);
      }
    } catch (_) {close('protocol_parse_stop');}
  });
  socket.on('error', () => close(initial ? 'frontend_transport_stop' : 'backend_transport_stop'));
  socket.on('end', () => {
    if (initial && target57014) return close('known_post57014_frontend_end', 0);
    if (initial && cfg.mode === 'observe' && identityRows === 1 && commandComplete && postExecuteReady) return close('observe_identity_complete_frontend_end', 0);
    if (!initial && terminateForwarded) return close('backend_end_after_original_terminate', target57014 || cfg.mode === 'observe' && identityRows === 1 && commandComplete && postExecuteReady ? 0 : 2);
    close(initial ? 'frontend_end_unproven_stop' : 'backend_end_unproven_stop');
  });
}
const server = net.createServer(socket => {
  if (accepted) {socket.destroy(); return close('second_connection_stop');}
  accepted = true; client = socket; server.close(); client.setNoDelay(true);
  evidence('one_connection_accepted');
  backend = net.connect({host: '127.0.0.1', port: 5463}); backend.setNoDelay(true);
  backend.once('connect', () => evidence('owned_backend_connected', {port: 5463}));
  framed(client, true, frontend); framed(backend, false, backendFrame);
});
server.on('error', () => close('listener_stop'));
server.listen(cfg.listen, '127.0.0.1', () => evidence('listener_ready', {port: cfg.listen, mode: cfg.mode, source_sha: sha(fs.readFileSync(__filename))}));
watchdog = setTimeout(() => close('watchdog_stop'), 30000);
process.once('SIGINT', () => close('operator_interrupt_stop'));
process.once('SIGTERM', () => close('operator_terminate_stop'));
evidence('draft_started', {target_sql_sha: sha(Buffer.from(IDENTITY)), frame_limit: MAX_FRAME, watchdog_ms: 30000});
