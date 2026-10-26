import { z } from 'zod';
import { applicationRoots,detectBundles,appleComponentSchema } from '../upstream/src/domain/apple/appleBundleAnatomy';
import { traceDylibLoading,machoSliceSchema } from '../upstream/src/domain/apple/dylibResolution';
import { checkpoint } from './runtime';
const path=z.string().min(1).max(4096).refine(p=>!p.startsWith('/')&&!p.split('/').includes('..'),'root-relative path');
const facts=z.discriminatedUnion('status',[
 z.strictObject({status:z.literal('parsed'),slices:z.array(machoSliceSchema).max(32)}),
 z.strictObject({status:z.enum(['malformed','unsupported']),reason:z.string().max(2048)}),
 z.strictObject({status:z.literal('not-mach-o')})]);
export const nativeInputSchema=z.strictObject({
 inventoryComplete:z.literal(true),
 subject:z.strictObject({name:z.string().max(4096),format:z.string().max(128)}),
 entries:z.array(z.strictObject({path,kind:z.enum(['file','directory','symlink','slice']),component:appleComponentSchema.optional(),target:z.string().max(4096).optional()})).max(20_000),
 images:z.array(z.strictObject({path,facts})).max(2048),roots:z.array(path).min(1).max(128),architecture:z.string().max(64).optional()
});
export async function nativeApplication(raw:unknown) {
 const input=nativeInputSchema.parse(raw);checkpoint();
 const entries=new Map(input.entries.map(e=>[e.path,e]));const images=new Map(input.images.map(e=>[e.path,e.facts]));
 if(entries.size!==input.entries.length||images.size!==input.images.length)throw new Error('duplicate path');
 let probes=0;
 const view={entry:async(p:string)=>{checkpoint();if(++probes>100_000)throw new Error('expansion budget');const e=entries.get(p);if(!e)return undefined;if(e.kind==='symlink'){if(e.target===undefined)throw new Error('missing symlink target');return {kind:'symlink' as const,target:e.target};}return {kind:e.kind==='directory'?'directory' as const:'file' as const};},
 image:async(p:string)=>{checkpoint();if(++probes>100_000)throw new Error('expansion budget');return images.get(p)??{status:'unsupported' as const,reason:'Mach-O facts not captured'};}};
 const roots=applicationRoots(input.entries,input.subject);
 const trace=await traceDylibLoading(view,{roots:input.roots,architecture:input.architecture,signal:{throwIfAborted:checkpoint} as AbortSignal});
 return {applicationRoots:roots,bundles:detectBundles(input.entries,roots),trace};
}
