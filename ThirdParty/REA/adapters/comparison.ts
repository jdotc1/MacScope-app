import { z } from 'zod';
import { compareProcessCaptures } from '../upstream/src/domain/process/processComparison.js';
import { canonical, checkpoint, guardJSON, sha256UTF8 } from './runtime.js';

const digest = z.string().regex(/^[0-9a-f]{64}$/);
const uint = z.number().int().nonnegative().safe();
const source = z.enum(['stdout','stderr','exit','filesystem','interaction','process']);
const relative = z.string().max(4096).refine(p => p === '.' || (!p.startsWith('/') && !p.split('/').some(c => c === '..' || c === '' || c === '.') && !p.includes('\0')), 'unsafe relative path');
const scenarioSchema = z.strictObject({
  arguments: z.array(z.string()).max(4096), environment: z.record(z.string(),z.string()),
  inputTreeSHA256: digest, workingDirectory: relative,
  interactions: z.array(z.strictObject({ atMS: uint, kind: z.enum(['stdin','signal','resize']), value: z.string() })).max(10000),
  dimensions: z.array(source).min(1).max(6).refine(v => new Set(v).size === v.length),
  normalization: z.strictObject({ kind: z.literal('exact-values-v1') }),
});
const observationSchema = z.strictObject({ order:uint, source, atMS:uint, value:z.unknown() });
const captureSchema = z.strictObject({
  captureID:z.string().min(1).max(128), scenario:scenarioSchema, scenarioSHA256:digest,
  executable:z.strictObject({sha256:digest,byteCount:uint}),
  producerReceipt:z.strictObject({receiptID:z.string().min(1),captureID:z.string(),scenarioSHA256:digest,executableSHA256:digest,inputTreeSHA256:digest,materializedInputTreeSHA256:digest}),
  observations:z.array(observationSchema).max(100000),
  completeSources:z.array(source).max(6), truncatedSources:z.array(source).max(6),
  cleanup:z.enum(['verifiedAbsent','failed','unknown']), execution:z.enum(['accepted','rejected']),
});
/** Host admission supplies digests only after checking authenticated broker receipts.
 * This adapter checks their binding; JSON supplied by a caller is not authentication. */
export const comparisonInputSchema=z.strictObject({
  left:captureSchema,right:captureSchema,
  admittedCaptureSHA256:z.tuple([digest,digest]),
});
export type ComparisonInput=z.infer<typeof comparisonInputSchema>;
type Capture=z.infer<typeof captureSchema>;
type Source=z.infer<typeof source>;
const fail=(reason:string):never=>{throw new Error('Invalid committed process capture: '+reason);};
function verify(c:Capture, admitted:string):void {
  checkpoint();
  if(sha256UTF8(canonical(c))!==admitted)fail('capture hash is not admitted');
  if(sha256UTF8(canonical(c.scenario))!==c.scenarioSHA256)fail('scenario commitment mismatch');
  const r=c.producerReceipt;
  if(r.captureID!==c.captureID || r.scenarioSHA256!==c.scenarioSHA256 || r.executableSHA256!==c.executable.sha256 || r.inputTreeSHA256!==c.scenario.inputTreeSHA256 || r.materializedInputTreeSHA256!==r.inputTreeSHA256)fail('producer receipt binding mismatch');
  if(new Set(c.completeSources).size!==c.completeSources.length || new Set(c.truncatedSources).size!==c.truncatedSources.length)fail('duplicate coverage declaration');
  const exits=c.observations.filter(o=>o.source==='exit');
  if(exits.length>1)fail('contradictory termination journal');
  let last=-1;
  for(let i=0;i<c.observations.length;i++) {
    if((i&255)===0)checkpoint();
    const o=c.observations[i];
    if(o.order!==i || o.atMS<last)fail('journal order contradiction');
    last=o.atMS;
    if(o.source==='stdout'||o.source==='stderr')z.string().parse(o.value);
    if(o.source==='exit') {
      const termination=z.strictObject({code:z.number().int().safe().nullable(),signal:z.string().nullable(),reason:z.enum(['exited','signaled','timeout','cancelled'])}).parse(o.value);
      if(termination.reason==='exited' && (termination.code===null || termination.signal!==null))fail('contradictory exited termination');
      if(termination.reason==='signaled' && (termination.signal===null || termination.code!==null))fail('contradictory signaled termination');
    }
    if(o.source==='filesystem')z.array(z.strictObject({path:relative,sha256:digest,byteCount:uint})).max(10000).parse(o.value);
    if(o.source==='interaction')z.strictObject({scheduledIndex:uint,kind:z.enum(['stdin','signal','resize']),value:z.string()}).parse(o.value);
    if(o.source==='process')z.strictObject({pid:uint,parent_pid:uint,command:z.string(),process_group_id:uint,session_id:uint}).parse(o.value);
  }
  if(c.completeSources.includes('exit') && exits.length!==1)fail('complete exit lacks termination');
  const interactions=c.observations.filter(o=>o.source==='interaction');
  interactions.forEach((o,index)=>{
    const v=o.value as any, planned=c.scenario.interactions[v.scheduledIndex];
    if(v.scheduledIndex!==index || !planned || planned.kind!==v.kind || planned.value!==v.value || planned.atMS!==o.atMS)fail('interaction contradicts committed schedule');
  });
  if(c.completeSources.includes('interaction') && interactions.length!==c.scenario.interactions.length)fail('complete interaction journal omits schedule');
  for(const o of c.observations.filter(o=>o.source==='filesystem')) {
    const paths=(o.value as any[]).map(v=>v.path);
    if(new Set(paths).size!==paths.length)fail('duplicate filesystem identity');
  }
}
/** Construct only observation projections. No upstream recorder or parser executes. */
function project(c:Capture,s:Source):any {
  const events=c.observations.filter(o=>o.source===s);
  const complete=c.execution==='accepted' && c.cleanup==='verifiedAbsent' && c.completeSources.includes(s) && !c.truncatedSources.includes(s);
  const frames=(s==='stdout'||s==='stderr')?events.map((o,i)=>({sequence:i,at_ms:0,data:o.value})):[];
  const byteCount=frames.reduce((n,o)=>n+new TextEncoderFallback().length(o.data as string),0);
  const retention={budget_bytes:byteCount,observed_bytes:byteCount,retained_bytes:byteCount,observed_frames:frames.length,retained_frames:frames.length};
  const scope=s==='stdout'||s==='stderr'?'terminal':s;
  return {
    manifest:{comparison_contract:c.scenario,comparison_contract_sha256:c.scenarioSHA256}, normalization:c.scenario.normalization,
    frames,rendered_frames:[],interaction_events:s==='interaction'?events.map(o=>({at_ms:o.atMS,...o.value as object})):[],
    exit:s==='exit'?events[0]?.value??{code:null,signal:null,reason:'unknown'}:{code:0,signal:null,reason:'exited'},
    settlement:{state:'quiesced',elapsed_ms:0,cleanup_outcome:'verified'},
    filesystem_checkpoints:s==='filesystem'?events.map(o=>({at_ms:0,files:o.value})):[],
    process_samples:s==='process'?events.map(o=>({at_ms:o.atMS,...o.value as object})):[],
    truncated:!complete,
    truncation_details:{raw_terminal:retention,rendered_terminal:retention,filesystem_before:{enumeration_truncated:false,hash_omissions:[]},filesystem_after:{enumeration_truncated:false,hash_omissions:[]},process:{sampling_partial:false}},
    residual_unknowns:complete?[]:[{scope,reason:'Producer coverage, accepted execution, or cleanup is incomplete.'}],limitations:[],
  };
}
// UTF-8 accounting without depending on Node or a recorder environment.
class TextEncoderFallback { length(value:string):number { let n=0;for(const c of value){const p=c.codePointAt(0)!;n+=p<128?1:p<2048?2:p<65536?3:4;}return n; } }
export function processComparison(raw:unknown):unknown {
  guardJSON(raw);const input=comparisonInputSchema.parse(raw);
  verify(input.left,input.admittedCaptureSHA256[0]);verify(input.right,input.admittedCaptureSHA256[1]);
  if(input.left.scenarioSHA256!==input.right.scenarioSHA256)return {status:'nonComparable',reason:'Scenario commitments differ.',dimensions:[]};
  const dimensions=input.left.scenario.dimensions.map(s=>{
    checkpoint();const a=project(input.left,s),b=project(input.right,s);
    const comparison=compareProcessCaptures(a,b);
    const dimension=s==='stdout'||s==='stderr'?'terminal':s;
    const status=(comparison as any)[dimension];
    return {source:s,status:status==='unchanged'?'equal':status==='unknown'?'unknown':'different',comparison};
  });
  return {status:dimensions.some(d=>d.status==='different')?'different':dimensions.some(d=>d.status==='unknown')?'unknown':'equal',dimensions,
    leftCaptureID:input.left.captureID,rightCaptureID:input.right.captureID,
    scenarioSHA256:input.left.scenarioSHA256,
    executableSHA256:[input.left.executable.sha256,input.right.executable.sha256]};
}
