'use strict';
const http=require('node:http'),assert=require('node:assert/strict');
const {ownedHttp}=require('../tools/owned-http-client.cjs');
async function main(){
 const server=http.createServer((req,res)=>{
  if(req.url==='/deny'){res.writeHead(403,{'Content-Type':'application/json',Connection:'close'});res.end('{"code":"access_denied"}');return;}
  if(req.url==='/large'){res.end('x'.repeat(2048));return;}
  if(req.url==='/hang')return;
  let chunks=[];req.on('data',b=>chunks.push(b));req.on('end',()=>{res.setHeader('Content-Type','application/json');res.end(JSON.stringify({length:Buffer.concat(chunks).length,declared:req.headers['content-length'],type:req.headers['content-type']}));});
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const port=server.address().port;
 try{
  const f=new FormData();f.set('file',new Blob([Buffer.from('fixed five-event fixture')]),'order.csv');f.set('delimiter','comma');
  const denied=await ownedHttp({port,route:'/deny',method:'POST',body:f});assert.equal(denied.status,403);assert.equal(denied.bytes.toString(),'{"code":"access_denied"}');
  const echo=JSON.parse((await ownedHttp({port,route:'/echo',method:'POST',body:f})).bytes);assert.equal(echo.length,Number(echo.declared));assert.match(echo.type,/^multipart\/form-data; boundary=pi-owned-/);
  await assert.rejects(ownedHttp({port,route:'/large',maxBytes:1024}),/http_response_bound/);
  await assert.rejects(ownedHttp({port,route:'/hang',timeoutMs:100}),/http_absolute_timeout/);
  process.stdout.write(JSON.stringify({status:'FINITE_HTTP_TRANSPORT_REGRESSION_PASSED',scenarios:['complete early403 without consuming upload','multipart exact Content-Length','oversized response refused','absolute timeout enforced'],limits:['Controlled loopback transport regression, not historic cause or product RBAC acceptance']})+'\n');
 }finally{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
}
main().catch(e=>{process.stderr.write(e.message+'\n');process.exitCode=1;});
