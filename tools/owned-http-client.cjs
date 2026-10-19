'use strict';
const http=require('node:http'),crypto=require('node:crypto');
async function encode(body,headers){
 if(body===undefined)return undefined;
 let buffer;
 if(body instanceof URLSearchParams){headers['Content-Type']='application/x-www-form-urlencoded';buffer=Buffer.from(body.toString());}
 else if(body instanceof FormData){
  const boundary='pi-owned-'+crypto.randomBytes(16).toString('hex'),parts=[];
  for(const[name,value]of body.entries()){
   if(!/^[a-z_]+$/.test(name))throw Error('multipart_field_name');
   const head='--'+boundary+'\r\nContent-Disposition: form-data; name="'+name+'"';
   if(typeof value==='string')parts.push(Buffer.from(head+'\r\n\r\n'+value+'\r\n'));
   else{
    if(!/^[a-zA-Z0-9_.-]+$/.test(value.name)||value.size>2*1024*1024)throw Error('multipart_file_bound');
    parts.push(Buffer.from(head+'; filename="'+value.name+'"\r\nContent-Type: application/octet-stream\r\n\r\n'),Buffer.from(await value.arrayBuffer()),Buffer.from('\r\n'));
   }
  }
  parts.push(Buffer.from('--'+boundary+'--\r\n'));buffer=Buffer.concat(parts);headers['Content-Type']='multipart/form-data; boundary='+boundary;
 }else if(Buffer.isBuffer(body))buffer=body;else throw Error('http_body_type');
 if(buffer.length>2*1024*1024)throw Error('http_request_body_bound');
 headers['Content-Length']=String(buffer.length);return buffer;
}
async function ownedHttp({port,route,method='GET',headers={},body,maxBytes=2*1024*1024,timeoutMs=15000}){
 if(!Number.isInteger(port)||port<1024||port>65535||!/^\/[a-zA-Z0-9/_.-]*$/.test(route)||route.includes('..')||!['GET','POST'].includes(method)||maxBytes<1||maxBytes>2*1024*1024||timeoutMs<1||timeoutMs>15000)throw Error('http_scope');
 headers={...headers,Connection:'close'};const bytes=await encode(body,headers);
 return await new Promise((resolve,reject)=>{
  let settled=false;const done=(error,result)=>{if(settled)return;settled=true;clearTimeout(timer);error?reject(error):resolve(result);};
  const req=http.request({hostname:'127.0.0.1',port,path:route,method,headers,agent:false},res=>{
   const chunks=[];let total=0;
   res.on('data',b=>{total+=b.length;if(total>maxBytes){done(Error('http_response_bound'));res.destroy();req.destroy();}else chunks.push(b);});
   res.on('aborted',()=>done(Error('http_response_aborted')));
   res.on('error',e=>done(e));
   res.on('end',()=>{if(!res.complete)return done(Error('http_response_incomplete'));done(null,{status:res.statusCode,headers:res.headers,bytes:Buffer.concat(chunks)});});
  });
  const timer=setTimeout(()=>{done(Error('http_absolute_timeout'));req.destroy();},timeoutMs);
  req.on('error',e=>done(e));req.end(bytes);
 });
}
module.exports={ownedHttp};
