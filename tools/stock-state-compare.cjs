'use strict';
// Additive stock restore/crash comparator. Raw captures remain unchanged.
// Cleanup/SQL5's frozen byte-exact capture and acceptance domain are not used here.
const fs=require('node:fs'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
function inspect(bytes){
 if(bytes.length>16*1024*1024)throw Error('stock_state_bound');
 const text=new TextDecoder('utf8',{fatal:true}).decode(bytes);
 if(!text.endsWith('\n'))throw Error('stock_state_missing_final_newline');
 const lines=text.slice(0,-1).split('\n');
 let sequence,definition;const others=[];
 for(const line of lines){
  const value=JSON.parse(line);
  if(value[0]==='sequence'){if(sequence)throw Error('duplicate_sequence');sequence=value;}
  else{others.push(line);if(value[0]==='sequence_definition'){if(definition)throw Error('duplicate_definition');definition=value;}}
 }
 if(!sequence||!definition||sequence.length!==4||sequence[3]!==true||!/^[1-9][0-9]*$/.test(sequence[1])||!/^[0-9]+$/.test(sequence[2]))throw Error('stock_sequence_shape');
 const last=BigInt(sequence[1]),logged=BigInt(sequence[2]);
 if(last>9223372036854775807n||logged>32n)throw Error('stock_sequence_bound');
 // Pinned PG18.6, positive bigint sequence, CACHE1 and increment1.
 if(JSON.stringify(definition)!==JSON.stringify(['sequence_definition','20','1','1','9223372036854775807','1','1',false]))throw Error('stock_sequence_definition');
 return {others:Buffer.from(others.join('\n')+'\n'),sequence,definition,last,logged,raw_sha256:sha(bytes)};
}
function compare(aBytes,bBytes,mode){
 if(!['restore','crash','exact'].includes(mode))throw Error('stock_comparison_mode');
 const a=inspect(aBytes),b=inspect(bBytes);
 if(!a.others.equals(b.others))throw Error('stock_non_sequence_changed');
 if(mode==='exact'&&!aBytes.equals(bBytes))throw Error('stock_raw_state_changed');
 if(mode==='restore'&&a.last!==b.last)throw Error('stock_restore_last_value_changed');
 if(mode==='crash'&&(b.last!==a.last&&b.last!==a.last+a.logged))throw Error('stock_crash_unexpected_reservation');
 if(mode==='crash'&&b.logged!==0n&&b.logged!==a.logged)throw Error('stock_crash_unexpected_log_count');
 if(mode==='crash'&&b.last!==a.last&&b.logged!==0n)throw Error('stock_crash_reservation_requires_zero_log_count');
 return {status:'STOCK_NAMED_COMPARISON_PASSED',mode,raw_equal:aBytes.equals(bBytes),left_raw_sha256:a.raw_sha256,right_raw_sha256:b.raw_sha256,non_sequence_bytes_exact:true,sequence_definition_exact:true,left_sequence:a.sequence,right_sequence:b.sequence,scope:mode==='restore'?'All non-sequence raw rows and semantic last_value/is_called/definition exact; physical WAL log_cnt reported separately':mode==='crash'?'All non-sequence raw rows exact; only unchanged or pinned prelogged WAL reservation allowed':'Entire raw capture exact'};
}
module.exports={compare};
if(require.main===module){
 try{process.stdout.write(JSON.stringify(compare(fs.readFileSync(process.argv[2]),fs.readFileSync(process.argv[3]),process.argv[4]))+'\n');}
 catch(e){process.stderr.write(e.message+'\n');process.exitCode=1;}
}
