import fs from 'node:fs';import vm from 'node:vm';import crypto from 'node:crypto';import assert from 'node:assert/strict';import path from 'node:path';import {fileURLToPath} from 'node:url';
const dir=path.dirname(fileURLToPath(import.meta.url));const resource=path.join(dir,'../generated/MacScopeREAKernel.js');
const canonical=v=>v===null||typeof v!=='object'?JSON.stringify(v):Array.isArray(v)?'['+v.map(canonical).join(',')+']':'{'+Object.keys(v).sort().map(k=>JSON.stringify(k)+':'+canonical(v[k])).join(',')+'}';
let cancelled=false,checks=0,checkpointFailure=null;
const context=vm.createContext({__macscopeSHA256:t=>crypto.createHash('sha256').update(t,'utf8').digest('hex'),__macscopeSHA256Base64:t=>crypto.createHash('sha256').update(Buffer.from(t,'base64')).digest('hex'),__macscopeCheckpoint:()=>{checks++;if(checkpointFailure&&checks===checkpointFailure.at)throw checkpointFailure.message;if(cancelled)throw Error('cancelled');}});
vm.runInContext(fs.readFileSync(resource,'utf8'),context,{timeout:10000});
const analyze=async value=>JSON.parse(await context.MacScopeREA.analyze(canonical({schemaVersion:1,requestID:'00000000-0000-4000-8000-000000000001',...value})));
const results=[];
for(const name of ['native','comparison','ui']) {const module=await import('./'+name+'.test.mjs');const result=await module.run(analyze);results.push({suite:name,...(result??{})});}
assert.equal(JSON.parse(await context.MacScopeREA.analyze('{"schemaVersion":1,"schemaVersion":1}')).ok,false);
assert.equal((await analyze({operation:'unknown',input:{}})).ok,false);
let deep={};for(let i=0;i<98;i++)deep={child:deep};assert.equal((await analyze({operation:'nativeApplication',input:deep})).ok,false);
assert.equal((await analyze({operation:'nativeApplication',input:{invalid:'\ud800'}})).ok,false);
assert.equal((await analyze({operation:'nativeApplication',input:Array(500001).fill(null)})).ok,false);
// Real kernel catch/serialization, including a code keyword beyond the retained prefix.
for(const [source,expected] of [
 ['a'.repeat(2048),'a'.repeat(1024)],
 ['é'.repeat(600),'é'.repeat(512)],
 ['😀'.repeat(600),'😀'.repeat(256)],
 ['a'.repeat(1022)+'😀tail','a'.repeat(1022)],
 ['a'.repeat(1021)+'étail','a'.repeat(1021)+'ét'],
 ['a'.repeat(1024)+' budget','a'.repeat(1024)],
 ['a'.repeat(1021)+'\ud800tail','a'.repeat(1021)+'\ufffd']
]) {
 checkpointFailure={at:checks+2,message:source};
 const reply=await analyze({operation:'nativeApplication',input:{}});
 checkpointFailure=null;
 assert.equal(reply.ok,false);assert.equal(reply.error.message,expected);
 assert.ok(Buffer.byteLength(reply.error.message,'utf8')<=1024);
 assert.equal(reply.error.code,/budget/.test(source)?'budget':'invalidInput');
 assert.equal(reply.requestID,'00000000-0000-4000-8000-000000000001');
}
cancelled=true;const cancellation=await analyze({operation:'nativeApplication',input:{}});assert.equal(cancellation.error.code,'cancelled');cancelled=false;
assert.ok(checks>0);console.log(JSON.stringify({ok:true,suites:results,checkpointCalls:checks,resourceSHA256:crypto.createHash('sha256').update(fs.readFileSync(resource)).digest('hex')}));
