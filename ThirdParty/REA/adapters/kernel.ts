import { Buffer,checkpoint,guardJSON,canonical } from './runtime';
import { nativeApplication } from './native';
import { uiResources } from './ui';
import { processComparison } from './comparison';
declare const __REA_IMPLEMENTATION_ID__:string;
export const implementationIdentity=__REA_IMPLEMENTATION_ID__;
// Match REAInspectionWireCodec's 1,024-byte diagnostic envelope. Iterating code
// points prevents a truncation boundary from splitting a UTF-16 surrogate pair.
function boundedDiagnostic(text:string):string {
 let result='',bytes=0;
 for(const point of text) {
  const scalar=point.codePointAt(0)!;
  const safe=scalar>=0xd800&&scalar<=0xdfff?'\uFFFD':point;
  const size=Buffer.byteLength(safe,'utf8');
  if(bytes+size>1024)break;
  result+=safe;bytes+=size;
 }
 return result;
}
export async function analyze(text:string):Promise<string> {
 let request:any;
 try {
  checkpoint();
  if(typeof text!=='string'||Buffer.byteLength(text,'utf8')>16*1024*1024)throw new Error('request budget');
  request=JSON.parse(text);guardJSON(request);
  if(canonical(request)!==text)throw new Error('noncanonical request');
  if(Object.keys(request).sort().join(',')!=='input,operation,requestID,schemaVersion'||request.schemaVersion!==1||
     typeof request.requestID!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(request.requestID))throw new Error('invalid request envelope');
  let result:any;checkpoint();
  switch(request.operation) {
   case 'nativeApplication':result=await nativeApplication(request.input);break;
   case 'uiResources':result=await uiResources(request.input);break;
   case 'processComparison':result=await processComparison(request.input);break;
   default:throw new Error('unsupported operation');
  }
  checkpoint();guardJSON(result);
  const response=canonical({schemaVersion:1,requestID:request.requestID,operation:request.operation,implementationIdentity,ok:true,result});
  if(Buffer.byteLength(response,'utf8')>8*1024*1024)throw new Error('response budget');
  checkpoint();return response;
 } catch(error) {
  const detail=String(error instanceof Error?error.message:error);
  const message=boundedDiagnostic(detail);
  return canonical({schemaVersion:1,requestID:typeof request?.requestID==='string'?request.requestID.slice(0,128):'',operation:typeof request?.operation==='string'?request.operation.slice(0,128):'',implementationIdentity,ok:false,error:{code:/cancel|deadline/i.test(detail)?'cancelled':/budget|limit/i.test(detail)?'budget':'invalidInput',message}});
 }
}
