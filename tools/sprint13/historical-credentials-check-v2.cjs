'use strict';
// Check only explicit, previously published synthetic fixture credentials.
// No network requests, password guesses, or stored credential changes.
const fs=require('node:fs'),crypto=require('node:crypto'),assert=require('node:assert/strict');
try{
 assert.equal(process.argv.length,5);
 const [capture,knownPath,output]=process.argv.slice(2);
 const fd=fs.openSync(capture,'r');let line=Buffer.alloc(0);
 try{const b=Buffer.alloc(16384);while(true){const n=fs.readSync(fd,b,0,b.length,null);assert(n>0);const end=b.subarray(0,n).indexOf(10);line=Buffer.concat([line,b.subarray(0,end<0?n:end)]);assert(line.length<=1024*1024);if(end>=0)break;}}finally{fs.closeSync(fd);}
 const row=JSON.parse(new TextDecoder('utf8',{fatal:true}).decode(line));assert.equal(row[0],'kv');assert.equal(row[1],'auth');
 const known=JSON.parse(fs.readFileSync(knownPath,'utf8').replace(/^\uFEFF/,''));
 const result={},checks=[];
 for(const [role,name] of Object.entries({owner:'qa_owner',editor:'qa_editor',viewer:'qa_viewer',foreign:'qa_other'})){
  const k=known[role];assert(k&&k.username===name&&typeof k.password==='string');
  const users=Object.values(row[3].users).filter(u=>u.username===name);assert.equal(users.length,1);
  const m=/^\$argon2id\$v=19\$m=19456,t=2,p=1\$([A-Za-z0-9+/]+)\$([A-Za-z0-9+/]+)$/.exec(users[0].password_hash);assert(m);
  const salt=Buffer.from(m[1],'base64'),expected=Buffer.from(m[2],'base64');assert.equal(salt.length,16);assert.equal(expected.length,32);
  const matched=crypto.timingSafeEqual(expected,crypto.argon2Sync('argon2id',{message:k.password,nonce:salt,parallelism:1,tagLength:32,memory:19456,passes:2}));
  checks.push({role,username:name,matched});if(matched)result[role]={username:name,password:k.password};
 }
 process.stdout.write(JSON.stringify({status:checks.every(c=>c.matched)?'FOUR_HISTORICAL_SYNTHETIC_CREDENTIALS_VERIFIED':'EXPLICIT_SYNTHETIC_CREDENTIAL_MISMATCH',checks,no_login:true,no_password_reset:true})+'\n');
 if(!checks.every(c=>c.matched)){process.exitCode=1;}else{
  const out=fs.openSync(output,'wx',0o600);try{fs.writeFileSync(out,JSON.stringify(result));fs.fsyncSync(out);}finally{fs.closeSync(out);}
 }
}catch{process.stderr.write('historical_explicit_fixture_credentials_check_failed\n');process.exitCode=1;}
