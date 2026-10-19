'use strict';
const assert=require('node:assert/strict');
const {namedProjectOpenId}=require('../tools/sprint12/named-project-row.cjs');
const id='project-00000000000040008000000000000001';
const row=`<tr><td>S12 project</td><td><form action="/projects/${id}/open"></form></td><td><table><tr><td>S12 project member</td></tr><tr><td>S12 project viewer</td></tr></table></td></tr>`;
assert.equal(namedProjectOpenId(row,'S12 project'),id);
for(const html of ['',row.replaceAll('S12 project','Other'),row+row]){
 assert.throws(()=>namedProjectOpenId(html,'S12 project'),/named_project_open_row_not_unique/);
}
assert.equal(namedProjectOpenId(row.replaceAll('S12 project','A &amp; B'),'A & B'),id);
process.stdout.write('PASS: five portable project selector cases\n');
