'use strict';
// Two finite owned HTTP mutations. Credentials/cookie remain in private files.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {ownedHttp}=require('./owned-http-client.cjs');
const cfg=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),mode=process.argv[3];
assert.equal(cfg.app_port,3095);assert.ok(['login','open'].includes(mode));
const root=cfg.output_directory,base='http://127.0.0.1:3095',privatePath=path.join(root,'auth-delta-private.json');
const write=(name,value)=>fs.writeFileSync(path.join(root,name),JSON.stringify(value,null,2),{flag:'wx'});
async function main(){
 let route,body,headers={Origin:base},state;
 if(mode==='login'){
  const credentials=JSON.parse(fs.readFileSync(cfg.credentials,'utf8')).owner;
  const seed=JSON.parse(fs.readFileSync(path.join(root,'http-private-state.json'),'utf8'));
  assert.match(seed.project,/^project-[a-z0-9]+$/);
  state={project:seed.project,username:credentials.username};
  route='/login';body=new URLSearchParams({username:credentials.username,password:credentials.password});
 }else{
  state=JSON.parse(fs.readFileSync(privatePath,'utf8'));
  assert.match(state.project,/^project-[a-z0-9]+$/);assert.match(state.cookie,/^pi_session=[a-f0-9]{64}$/);
  route='/projects/'+state.project+'/open';body=new URLSearchParams();headers.Cookie=state.cookie;
 }
 const started=new Date().toISOString(),result=await ownedHttp({port:3095,route,method:'POST',headers,body}),ended=new Date().toISOString();
 assert.equal(result.status,303);assert.equal(result.headers.location,mode==='login'?'/projects':'/logs');
 if(mode==='login'){
  const cookies=result.headers['set-cookie'];assert.ok(Array.isArray(cookies)&&cookies.length===1);
  assert.match(cookies[0],/HttpOnly/i);assert.match(cookies[0],/SameSite=Strict/i);
  state.cookie=cookies[0].split(';')[0];assert.match(state.cookie,/^pi_session=[a-f0-9]{64}$/);
  write('auth-delta-private.json',state);
 }else assert.equal(result.headers['set-cookie'],undefined);
 write('auth-'+mode+'-http.json',{status:'FINITE_AUTH_HTTP_MUTATION_COMPLETED',mode,route,http_status:result.status,location:result.headers.location,started_utc:started,ended_utc:ended,response_bytes:result.bytes.length,response_sha256:crypto.createHash('sha256').update(result.bytes).digest('hex')});
 process.stdout.write(JSON.stringify({status:'FINITE_AUTH_HTTP_MUTATION_COMPLETED',mode,http_status:result.status})+'\n');
}
main().catch(e=>{try{write('auth-'+mode+'-http-failure.json',{status:'FAILED_RETAINED',mode,reason:e.message});}catch{}process.exitCode=1;});
