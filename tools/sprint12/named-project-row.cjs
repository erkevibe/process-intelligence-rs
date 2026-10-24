'use strict';
// Fixture selector: nested membership rows repeat project names but have no open form.
function namedProjectOpenId(html,name){
 const escaped=name.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
 const rows=[...html.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/g)].map(m=>m[1]);
 const open=/action="\/projects\/(project-[a-f0-9]{32})\/open"/;
 const candidates=rows.filter(row=>row.includes(escaped)&&open.test(row));
 if(candidates.length!==1)throw Error('named_project_open_row_not_unique');
 return candidates[0].match(open)[1];
}
module.exports={namedProjectOpenId};
