import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
const canonical=v=>v===null||typeof v!=='object'?JSON.stringify(v):Array.isArray(v)?'['+v.map(canonical).join(',')+']':'{'+Object.keys(v).sort().map(k=>JSON.stringify(k)+':'+canonical(v[k])).join(',')+'}';
const hash=v=>createHash('sha256').update(canonical(v)).digest('hex');
const copy=v=>JSON.parse(JSON.stringify(v));
export async function run(analyze) {
  const scenario={arguments:['--sample'],environment:{LANG:'C'},inputTreeSHA256:'1'.repeat(64),workingDirectory:'.',interactions:[],dimensions:['stdout','stderr','exit','filesystem'],normalization:{kind:'exact-values-v1'}};
  const capture=(id,exe)=>{
    const scenarioSHA256=hash(scenario);
    return {captureID:id,scenario:copy(scenario),scenarioSHA256,executable:{sha256:exe.repeat(64),byteCount:12},producerReceipt:{receiptID:'receipt-'+id,captureID:id,scenarioSHA256,executableSHA256:exe.repeat(64),inputTreeSHA256:scenario.inputTreeSHA256,materializedInputTreeSHA256:scenario.inputTreeSHA256},observations:[{order:0,source:'stdout',atMS:0,value:'hello\n'},{order:1,source:'stderr',atMS:1,value:''},{order:2,source:'filesystem',atMS:2,value:[{path:'output.txt',sha256:'2'.repeat(64),byteCount:6}]},{order:3,source:'exit',atMS:3,value:{code:0,signal:null,reason:'exited'}}],completeSources:copy(scenario.dimensions),truncatedSources:[],cleanup:'verifiedAbsent',execution:'accepted'};
  };
  const left=capture('left','a'),right=capture('right','b');
  const invoke=async(l=left,r=right,admitted=[hash(l),hash(r)])=>{
    const response=await analyze({operation:'processComparison',input:{left:l,right:r,admittedCaptureSHA256:admitted}});
    if(response.error)throw new Error(typeof response.error==='string'?response.error:JSON.stringify(response.error));
    return response.result??response;
  };
  right.observations.forEach(o=>o.atMS+=10);
  assert.equal((await invoke()).status,'equal','different actual executables may have equal complete behavior');
  for(const dimension of ['stdout','exit','filesystem']) {
    const changed=copy(right);
    const event=changed.observations.find(o=>o.source===dimension);
    if(dimension==='stdout')event.value='different\n';
    if(dimension==='exit')event.value.code=1;
    if(dimension==='filesystem')event.value[0].sha256='3'.repeat(64);
    const result=await invoke(left,changed);
    assert.equal(result.status,'different');
    assert.equal(result.dimensions.find(d=>d.source===dimension).status,'different');
  }
  const incomplete=copy(right);incomplete.completeSources=[];
  assert.equal((await invoke(incomplete,incomplete)).status,'unknown','identical incomplete evidence cannot establish equality');
  const cleanup=copy(right);cleanup.cleanup='failed';
  assert.equal((await invoke(left,cleanup)).status,'unknown');
  const truncated=copy(right);truncated.truncatedSources=['stdout'];
  assert.equal((await invoke(left,truncated)).dimensions.find(d=>d.source==='stdout').status,'unknown');
  const other=copy(right);other.scenario.arguments=['--other'];other.scenarioSHA256=hash(other.scenario);other.producerReceipt.scenarioSHA256=other.scenarioSHA256;
  assert.equal((await invoke(left,other)).status,'nonComparable');
  await assert.rejects(()=>invoke(left,right,[hash(left),'0'.repeat(64)]),/admitted|hash/);
  const forged=copy(right);forged.scenarioSHA256='0'.repeat(64);
  await assert.rejects(()=>invoke(left,forged),/commitment/);
  const wrongReceipt=copy(right);wrongReceipt.producerReceipt.executableSHA256='0'.repeat(64);
  await assert.rejects(()=>invoke(left,wrongReceipt),/binding/);
  const wrongTree=copy(right);wrongTree.producerReceipt.materializedInputTreeSHA256='0'.repeat(64);
  await assert.rejects(()=>invoke(left,wrongTree),/binding/);
  const journal=copy(right);journal.observations[1].order=0;
  await assert.rejects(()=>invoke(left,journal),/journal/);
  const exit=copy(right);exit.observations.push({...copy(exit.observations[3]),order:4});
  await assert.rejects(()=>invoke(left,exit),/termination/);
  const unsafe=copy(right);unsafe.observations[2].value[0].path='../escape';
  await assert.rejects(()=>invoke(left,unsafe),/path|relative/);
  const missing=copy(right);missing.observations.pop();
  await assert.rejects(()=>invoke(left,missing),/termination/);
  const contradictory=copy(right);contradictory.observations[3].value.signal='SIGKILL';
  await assert.rejects(()=>invoke(left,contradictory),/termination/);
  return {cases:17,status:'passed'};
}
