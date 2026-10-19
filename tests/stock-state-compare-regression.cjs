'use strict';
const assert=require('node:assert/strict'),{compare}=require('../tools/stock-state-compare.cjs');
function fixture(last,logged,value='original'){
 return Buffer.from([JSON.stringify(['kv','auth','1',{fixture:value}]),JSON.stringify(['sequence',String(last),String(logged),true]),JSON.stringify(['sequence_definition','20','1','1','9223372036854775807','1','1',false])].join('\n')+'\n');
}
const original=fixture(2,31),restored=fixture(2,0),crashed=fixture(33,0);
assert.equal(compare(original,restored,'restore').raw_equal,false);
assert.equal(compare(original,crashed,'crash').non_sequence_bytes_exact,true);
assert.equal(compare(original,original,'exact').raw_equal,true);
assert.throws(()=>compare(original,restored,'exact'),/stock_raw_state_changed/);
assert.throws(()=>compare(original,fixture(3,0),'restore'),/stock_restore_last_value_changed/);
assert.throws(()=>compare(original,fixture(34,0),'crash'),/stock_crash_unexpected_reservation/);
assert.throws(()=>compare(original,fixture(2,0,'changed'),'restore'),/stock_non_sequence_changed/);
assert.throws(()=>compare(original,fixture(33,1),'crash'),/stock_crash_unexpected_log_count/);
assert.throws(()=>compare(original,fixture(33,31),'crash'),/stock_crash_reservation_requires_zero_log_count/);
process.stdout.write(JSON.stringify({status:'FINITE_STOCK_STATE_REGRESSION_PASSED',scenarios:9,limits:['Synthetic policy regression; live recovery requires separate proof','Cleanup/SQL5 frozen raw comparator unchanged']})+'\n');
