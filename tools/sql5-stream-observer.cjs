'use strict';
// Sprint11 diagnostic observer. No children, query/OPTIONS changes, synthesized protocol or row logs.
const net = require('node:net'), fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const utf = new TextDecoder('utf8', {fatal:true});
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const TARGET = 'SELECT version,document,octet_length(document::text)::bigint FROM public.pi_kv WHERE key=$1';
const FRONT_MAX = 1048576, ROW_MAX = 268435456, CONTROL_MAX = 65536, QUEUE_MAX = 2097152;
const configPath = process.env.PI_FULL_OBSERVER_CONFIG;
if (!configPath || !path.isAbsolute(configPath)) throw Error('config_path_stop');
const configBytes = fs.readFileSync(configPath);
if (configBytes.length > 1048576) throw Error('config_bound_stop');
const cfg = JSON.parse(utf.decode(configBytes).replace(/^\uFEFF/,''));
const hashPattern = /^[a-f0-9]{64}$/;
if (!['observe','hold'].includes(cfg.mode) || cfg.backend_port !== 5463 ||
    !Number.isInteger(cfg.listen_port) || cfg.listen_port < 1024 || cfg.listen_port > 65535 || cfg.listen_port === cfg.backend_port ||
    !/^[a-z][a-z0-9_]{1,62}$/.test(cfg.database || '') || !hashPattern.test(cfg.options_sha || '') ||
    !hashPattern.test(cfg.plan_sha || '') || !hashPattern.test(cfg.target_key_sha || '') ||
    !path.isAbsolute(cfg.plan_path || '') || !path.isAbsolute(cfg.evidence_path || '') ||
    !Array.isArray(cfg.allowed_parse_sha) || cfg.allowed_parse_sha.length > 256 ||
    cfg.allowed_parse_sha.some(x => !hashPattern.test(x)) ||
    !Array.isArray(cfg.allowed_simple) || cfg.allowed_simple.length > 64 ||
    cfg.allowed_simple.some(x => !hashPattern.test(x.sha || '') || !Number.isInteger(x.commands) || x.commands < 1 || x.commands > 4)) throw Error('config_contract_stop');
const planBytes = fs.readFileSync(cfg.plan_path);
if (planBytes.length > 4194304 || sha(planBytes) !== cfg.plan_sha) throw Error('plan_binding_stop');
const plan = JSON.parse(utf.decode(planBytes).replace(/^\uFEFF/,''));
if (!Array.isArray(plan.candidates) || plan.candidates.length !== 10) throw Error('whole_plan10_stop');
const keys = plan.candidates.map(c => c.key);
if (new Set(keys).size !== 10 || keys.some(k => typeof k !== 'string' || Buffer.byteLength(k) > 512)) throw Error('plan_keys_stop');
const targetKeys = keys.filter(k => sha(Buffer.from(k)) === cfg.target_key_sha);
if (targetKeys.length !== 1) throw Error('ambiguous_target_binding_stop');
const targetKey = targetKeys[0], allowedParse = new Set(cfg.allowed_parse_sha);
if (!allowedParse.has(sha(Buffer.from(TARGET)))) throw Error('target_not_allowlisted_stop');
const allowedSimple = new Map(cfg.allowed_simple.map(x => [x.sha,x.commands]));
if (allowedParse.size !== cfg.allowed_parse_sha.length || allowedSimple.size !== cfg.allowed_simple.length) throw Error('duplicate_allowlist_stop');
const fd = fs.openSync(cfg.evidence_path,'wx',0o600), start = process.hrtime.bigint();
let closed=false, accepted=false, seq=0, client, backend, watchdog, timer, startupReady=false, pid;
let selected, heldE, heldS, bindWritten, armed=false, released=false, target57014=false, terminated=false;
let targetExecutions=0, targetRows=0, targetCompleted=false;
const statements=new Map(), portals=new Map(), responses=[], descriptions=[], commands=[], syncs=[];
let frontendCycle=1, backendCycle=1;
function event(kind, data={}) {
  if (closed) return;
  fs.writeSync(fd,JSON.stringify({seq:++seq,utc:new Date().toISOString(),elapsed_ms:Number(process.hrtime.bigint()-start)/1e6,kind,...data})+'\n');
}
function stop(reason, code=2) {
  if (closed) return;
  event('stop',{reason,target_executions:targetExecutions,actual_bind_complete:!!selected?.complete,
    bind_write_complete:bindWritten!==undefined,held_execute:!!heldE,held_sync:!!heldS,
    original_pair_released:released,actual_target57014:target57014,target_rows:targetRows,target_completed:targetCompleted});
  closed=true;clearTimeout(timer);clearTimeout(watchdog);client?.destroy();backend?.destroy();
  server.close();fs.fsyncSync(fd);fs.closeSync(fd);process.exitCode=code;
}
function str(b,o=0) {const e=b.indexOf(0,o);if(e<0)throw Error('cstring_stop');return [utf.decode(b.subarray(o,e)),e+1];}
function send(socket, bytes, source, callback) {
  if(closed)return;
  if(socket.writableLength+bytes.length>QUEUE_MAX)return stop('write_queue_bound_stop');
  const okay=socket.write(bytes,()=>{if(!closed&&callback)callback();});
  if(!okay&&source){source.pause();socket.once('drain',()=>{if(!closed)source.resume();});}
}
function arm() {
  if(cfg.mode!=='hold'||armed||bindWritten===undefined||!heldE||!heldS)return;
  const lag=Number(process.hrtime.bigint()-bindWritten)/1e6;
  if(lag>250)return stop('target_original_cycle_capture_late_stop');
  armed=true;event('hold_armed',{deadline_ms_from_bind_write:6500,capture_lag_ms:lag,bind_complete_already_seen:selected.complete,execute_sha:sha(heldE),sync_sha:sha(heldS),backend_pid:pid});
  timer=setTimeout(()=>{if(closed)return;released=true;event('original_pair_release_requested',{execute_sha:sha(heldE),sync_sha:sha(heldS)});
    send(backend,heldE,null,()=>event('original_execute_write_complete'));
    send(backend,heldS,null,()=>event('original_sync_write_complete'));
  },Math.max(1,6500-lag));
}
function frontend(f) {
  const t=String.fromCharCode(f[0]),b=f.subarray(5);
  if(t==='X') {
    if(b.length||heldE&&!released&&!target57014)return stop('terminate_unproven_phase_stop');
    event(target57014?'known_post57014_original_terminate':'actual_original_terminate',{pair_unreleased:!!heldE&&!released});
    if(target57014)clearTimeout(timer);
    send(backend,f,client,()=>{terminated=true;event('original_terminate_write_complete');if(target57014)stop('known_post57014_terminate',0);});return;
  }
  if(heldE&&!released&&t!=='S'&&!(target57014&&t==='C'))return stop('unknown_held_phase_stop');
  if(t==='P') {
    if(!startupReady||statements.size>=256)throw Error('parse_phase_or_map_bound_stop');
    const [name,o]=str(b),[sql,e]=str(b,o),hash=sha(Buffer.from(sql));
    if(e+2>b.length||e+2+4*b.readUInt16BE(e)!==b.length||!allowedParse.has(hash)||statements.has(name))throw Error('parse_allowlist_shape_stop');
    const n=b.readUInt16BE(e),isTarget=sql===TARGET;
    if(isTarget&&(n>1||n===1&&![0,25,1043].includes(b.readUInt32BE(e+2))))throw Error('target_parse_type_stop');
    const s={hash,target:isTarget,declared:n,parameters:undefined,complete:false};statements.set(name,s);responses.push({type:'1',value:s,cycle:frontendCycle});
    event('actual_parse',{sql_sha:hash,target:isTarget,parameter_types:n,cycle:frontendCycle});
  } else if(t==='B') {
    const [portal,o1]=str(b),[name,o2]=str(b,o1),s=statements.get(name);
    const previous=portals.get(portal);
    if(!s||!s.complete||!previous&&portals.size>=256)throw Error('bind_statement_phase_stop');
    // PostgreSQL's unnamed portal is replaced by a new Bind. Permit this only
    // after its actual CommandComplete and with no response still referring to it.
    if(previous&&(portal!==''||!previous.completed||responses.some(x=>x.value===previous)||
        descriptions.some(x=>x.value===previous)||commands.some(x=>x.portal===previous)))throw Error('bind_pending_portal_replacement_stop');
    let o=o2;const u=()=>{if(o+2>b.length)throw Error('bind_bounds_stop');const n=b.readUInt16BE(o);o+=2;return n;};
    const nf=u(),formats=[];if(nf>64)throw Error('bind_formats_bound_stop');
    for(let i=0;i<nf;i++){const v=u();if(v>1)throw Error('bind_format_stop');formats.push(v);}
    const np=u(),values=[];if(np>64||np!==s.parameters||![0,1,np].includes(nf))throw Error('bind_parameter_count_stop');
    for(let i=0;i<np;i++){if(o+4>b.length)throw Error('bind_parameter_bounds_stop');const n=b.readInt32BE(o);o+=4;
      if(n< -1||n>FRONT_MAX||n>=0&&o+n>b.length)throw Error('bind_parameter_length_stop');
      values.push(n<0?null:b.subarray(o,o+n));if(n>=0)o+=n;}
    const nr=u();if(nr>64)throw Error('bind_results_bound_stop');for(let i=0;i<nr;i++)if(u()>1)throw Error('bind_result_format_stop');
    if(o!==b.length)throw Error('bind_trailing_stop');
    let target=false;
    if(s.target){if(np!==1||!values[0]||values[0].length>512)throw Error('target_bind_shape_stop');
      const key=utf.decode(values[0]);if(!keys.includes(key))throw Error('target_sql_key_outside_full_plan_stop');target=key===targetKey;}
    const p={statement:s,target,complete:false,executed:false,completed:false};portals.set(portal,p);responses.push({type:'2',value:p,cycle:frontendCycle});
    if(target){if(selected)throw Error('repeated_target_bind_stop');selected=p;
      event('actual_target_bind',{key_sha:cfg.target_key_sha,frame_sha:sha(f),parameter_count:np,parameter_format:nf?formats[0]:0});
      send(backend,f,client,()=>{bindWritten=process.hrtime.bigint();event('original_target_bind_write_complete',{frame_sha:sha(f)});arm();});return;}
  } else if(t==='E') {
    const [name,o]=str(b),p=portals.get(name);
    if(!p||p.executed||o+4!==b.length||b.readUInt32BE(o)!==0||commands.length)throw Error('execute_phase_stop');
    p.executed=true;commands.push({target:p.target,portal:p,cycle:frontendCycle});
    if(p.target){if(++targetExecutions!==1)throw Error('repeated_target_execute_stop');event('actual_target_original_execute',{frame_sha:sha(f)});
      if(cfg.mode==='hold'){heldE=Buffer.from(f);arm();return;}}
  } else if(t==='S') {
    if(b.length)throw Error('sync_shape_stop');syncs.push(frontendCycle++);
    if(cfg.mode==='hold'&&heldE&&!released){if(heldS)throw Error('duplicate_target_sync_stop');heldS=Buffer.from(f);event('actual_target_original_sync_captured',{frame_sha:sha(f)});arm();return;}
  } else if(t==='D'||t==='C') {
    if(!b.length)throw Error('describe_close_shape_stop');const kind=String.fromCharCode(b[0]),[name,o]=str(b,1);
    if(o!==b.length||!((kind==='S'&&statements.has(name))||(kind==='P'&&portals.has(name))))throw Error('describe_close_map_stop');
    if(t==='C'){responses.push({type:'3',kind,name,cycle:frontendCycle});}
    else {if(descriptions.length>=512)throw Error('describe_queue_bound_stop');descriptions.push({kind,value:kind==='S'?statements.get(name):portals.get(name),cycle:frontendCycle});}
  } else if(t==='Q') {
    const [sql,o]=str(b),hash=sha(Buffer.from(sql)),count=allowedSimple.get(hash);
    if(!startupReady||o!==b.length||!count||commands.length)throw Error('simple_query_allowlist_phase_stop');
    for(let i=0;i<count;i++)commands.push({target:false,cycle:frontendCycle});syncs.push(frontendCycle++);event('actual_simple_query',{sql_sha:hash,expected_commands:count});
  } else if(t==='H') {if(b.length)throw Error('flush_shape_stop');}
  else if(t==='p'){if(startupReady)throw Error('auth_after_startup_stop');}
  else throw Error('unknown_frontend_type_stop');
  if(responses.length>512||commands.length>8||syncs.length>8)throw Error('protocol_queue_bound_stop');
  send(backend,f,client);
}
function control(t,b) {
  if(['1','2','3'].includes(t)) {
    const p=responses.shift();if(b.length||!p||p.type!==t||p.cycle!==backendCycle)throw Error('backend_completion_map_stop');
    if(t==='3'){if(p.kind==='S')statements.delete(p.name);else portals.delete(p.name);}
    else {p.value.complete=true;if(t==='2'&&p.value.target){event('actual_target_bind_complete',{backend_pid:pid});arm();}}
  } else if(t==='t') {
    const d=descriptions[0];if(!d||d.cycle!==backendCycle||d.kind!=='S'||b.length<2)throw Error('parameter_description_phase_stop');
    const n=b.readUInt16BE(0);if(n>64||b.length!==2+4*n||d.value.declared&&d.value.declared!==n)throw Error('parameter_description_shape_stop');
    if(d.value.target&&(n!==1||![25,1043].includes(b.readUInt32BE(2))))throw Error('target_actual_parameter_type_stop');
    d.value.parameters=n;
  } else if(t==='T'||t==='n') {
    if(!descriptions.length||descriptions[0].cycle!==backendCycle||t==='n'&&b.length)throw Error('row_description_phase_stop');descriptions.shift();
  } else if(t==='K') {if(b.length!==8||pid!==undefined)throw Error('backend_pid_shape_stop');pid=b.readUInt32BE(0);event('actual_backend_pid',{backend_pid:pid});}
  else if(t==='C') {if(!b.length||b[b.length-1]!==0||!commands.length)throw Error('command_completion_phase_stop');const c=commands.shift();
    if(c.cycle!==backendCycle)throw Error('command_completion_cycle_stop');
    if(c.portal)c.portal.completed=true;
    if(c.target){if(utf.decode(b.subarray(0,b.length-1))!=='SELECT 1'||targetRows!==1)throw Error('target_completion_shape_stop');targetCompleted=true;event('actual_target_command_complete',{target_rows:targetRows,actual_tag:'SELECT 1'});}}
  else if(t==='E') {
    let o=0,state,reason;while(o<b.length&&b[o]){const code=String.fromCharCode(b[o++]),[value,next]=str(b,o);o=next;if(code==='C')state=value;if(code==='M')reason=value;}
    if(o!==b.length-1||!state||!/^[0-9A-Z]{5}$/.test(state))throw Error('server_error_shape_stop');
    const isTarget=commands[0]?.cycle===backendCycle&&!!commands[0]?.target;
    const timeoutReason=reason==='canceling statement due to statement timeout';
    if(state==='57014'&&isTarget){if(!timeoutReason||!selected?.complete||bindWritten===undefined||!heldE||!heldS||!armed||pid===undefined)throw Error('57014_unproven_target_phase_stop');target57014=true;}
    event('actual_server_error',{sqlstate:state,backend_pid:pid,target_execution:isTarget,statement_timeout_reason_verified:timeoutReason,before_pair_release:!!heldE&&!released,cycle:backendCycle});
    for(const queue of [commands,responses,descriptions])while(queue.length&&queue[0].cycle===backendCycle)queue.shift();
  } else if(t==='Z') {
    if(b.length!==1||!['I','T','E'].includes(String.fromCharCode(b[0])))throw Error('ready_shape_stop');
    if(startupReady){
      if(!syncs.length||syncs[0]!==backendCycle)throw Error('unexpected_ready_stop');
      // prepare.rs returns after RowDescription; a later P/D/S may already be
      // queued before this Z. Only this exact FIFO cycle must be complete.
      if([commands,responses,descriptions].some(q=>q.some(x=>x.cycle<=backendCycle)))throw Error('unfinished_cycle_stop');
      syncs.shift();event('actual_cycle_complete',{cycle:backendCycle,pending_later_responses:responses.length,pending_later_descriptions:descriptions.length,pending_later_commands:commands.length});backendCycle++;
    }
    startupReady=true;event('actual_ready',{status:String.fromCharCode(b[0])});
  }
}
function backendStream() {
  let head=Buffer.alloc(0),remaining=0,type,capture=null,rowShape=null;
  function rowPiece(piece) {
    if(!rowShape)return;
    let o=0;
    while(o<piece.length){
      if(rowShape.skip){const n=Math.min(rowShape.skip,piece.length-o);rowShape.skip-=n;o+=n;continue;}
      const need=rowShape.columns===null?2:4,n=Math.min(need-rowShape.header.length,piece.length-o);
      rowShape.header=Buffer.concat([rowShape.header,piece.subarray(o,o+n)]);o+=n;
      if(rowShape.header.length<need)continue;
      if(rowShape.columns===null){rowShape.columns=rowShape.header.readUInt16BE(0);if(rowShape.columns!==3)throw Error('target_row_columns_stop');}
      else {if(++rowShape.fields>3)throw Error('target_row_extra_field_stop');const len=rowShape.header.readInt32BE(0);if(len<0)throw Error('target_row_null_stop');rowShape.skip=len;}
      rowShape.header=Buffer.alloc(0);
    }
  }
  backend.on('data',data=>{if(closed)return;try{let o=0;
    while(o<data.length&&!closed){if(!remaining){const n=Math.min(5-head.length,data.length-o);head=Buffer.concat([head,data.subarray(o,o+n)]);o+=n;if(head.length<5)continue;
      const len=head.readUInt32BE(1);type=String.fromCharCode(head[0]);if(len<4||len>ROW_MAX||type!=='D'&&len>CONTROL_MAX)throw Error('backend_frame_bound_stop');
      if(!['R','S','K','Z','1','2','3','t','T','n','D','C','E','N','A'].includes(type))throw Error('unknown_backend_type_stop');
      remaining=len-4;capture=['K','Z','1','2','3','C','E','t','T','n'].includes(type)?[]:null;
      rowShape=null;
      if(type==='D'&&commands[0]?.target){if(commands[0].cycle!==backendCycle)throw Error('target_row_cycle_stop');if(++targetRows!==1)throw Error('target_row_count_stop');rowShape={columns:null,fields:0,skip:0,header:Buffer.alloc(0)};event('actual_target_datarow_header',{frame_bytes:len+1});}
      send(client,head,backend);head=Buffer.alloc(0);
      if(!remaining){control(type,Buffer.alloc(0));continue;}}
      const n=Math.min(remaining,data.length-o),piece=data.subarray(o,o+n);o+=n;remaining-=n;
      if(capture)capture.push(Buffer.from(piece));
      rowPiece(piece);
      send(client,piece,backend);
      if(!remaining&&rowShape){if(rowShape.columns!==3||rowShape.fields!==3||rowShape.skip||rowShape.header.length)throw Error('target_row_incomplete_shape_stop');event('actual_target_datarow_shape',{columns:3,fields:3,payload_logged:false});rowShape=null;}
      if(!remaining&&capture)control(type,Buffer.concat(capture));
    }
  }catch(e){stop(e.message);}});
}
function frontendFrames() {
  let pending=Buffer.alloc(0),startup=true;
  client.on('data',data=>{if(closed)return;try{
    if(pending.length+data.length>QUEUE_MAX)throw Error('frontend_read_queue_stop');pending=Buffer.concat([pending,data]);
    while(!closed){if(pending.length<(startup?4:5))break;const n=pending.readUInt32BE(startup?0:1),total=startup?n:n+1;
      if(n<(startup?8:4)||total>FRONT_MAX)throw Error('frontend_frame_bound_stop');if(pending.length<total)break;
      const f=pending.subarray(0,total);pending=pending.subarray(total);
      if(startup){if(f.readUInt32BE(4)!==196608)throw Error('NoTls_protocol3_stop');const values=new Map();let o=8;
        while(o<f.length&&f[o]){const [k,next]=str(f,o),[v,end]=str(f,next);if(values.has(k))throw Error('startup_duplicate_stop');values.set(k,v);o=end;}
        if(o!==f.length-1||values.get('database')!==cfg.database||values.get('application_name')!=='pi_cleanup_offline'||sha(Buffer.from(values.get('options')||''))!==cfg.options_sha)throw Error('startup_identity_options_stop');
        event('actual_startup_admitted',{database_sha:sha(Buffer.from(cfg.database)),options_sha:cfg.options_sha});startup=false;send(backend,f,client);
      }else frontend(f);
    }
  }catch(e){stop(e.message);}});
}
const server=net.createServer(socket=>{
  if(accepted){socket.destroy();return stop('second_connection_stop');}accepted=true;client=socket;server.close();client.setNoDelay(true);
  backend=net.connect({host:'127.0.0.1',port:cfg.backend_port,readableHighWaterMark:65536});backend.setNoDelay(true);
  event('one_owned_connection_accepted');frontendFrames();backendStream();
  client.on('error',()=>stop('frontend_transport_stop'));backend.on('error',()=>stop('backend_transport_stop'));
  client.on('end',()=>stop(target57014?'known_post57014_frontend_end':'frontend_end',target57014||cfg.mode==='observe'&&targetCompleted?0:2));
  backend.on('end',()=>stop(terminated?'backend_end_after_original_terminate':'backend_end_unproven_stop',terminated&&(target57014||cfg.mode==='observe'&&targetCompleted)?0:2));
});
server.on('error',()=>stop('listener_stop'));
server.listen(cfg.listen_port,'127.0.0.1',()=>event('listener_ready',{port:cfg.listen_port,mode:cfg.mode,script_sha:sha(fs.readFileSync(__filename)),config_sha:sha(configBytes),plan_sha:cfg.plan_sha,target_key_sha:cfg.target_key_sha,target_sql_sha:sha(Buffer.from(TARGET))}));
watchdog=setTimeout(()=>stop('absolute_watchdog_stop'),300000);
process.once('SIGINT',()=>stop('operator_interrupt_stop'));process.once('SIGTERM',()=>stop('operator_terminate_stop'));
