// Selected REA algorithms are MIT licensed; see ../LICENSE and SOURCE_MANIFEST.json.
import { z } from 'zod';
import { Buffer, TextDecoder, checkpoint, guardJSON, sha256Base64 } from './runtime';
import { decodeNibArchive, type NibArchiveDocument } from '../upstream/src/artifacts/apple/NibArchive';
import { InterfaceBuilderDecodeBudget, InterfaceBuilderDecodeBudgetExceeded } from '../upstream/src/artifacts/apple/InterfaceBuilderDecodeBudget';
import { projectNibViewHierarchy, mergeNibHierarchies, type NibHierarchyNode } from '../upstream/src/artifacts/apple/NibViewHierarchy';
import { buildInterfaceBuilderAnalysis, interfaceBuilderLimitsSchema, type InterfaceBuilderDocumentInput } from '../upstream/src/domain/apple/interfaceBuilderGraph';
import { projectKeyedArchive } from '../upstream/src/domain/apple/keyedArchive';
import { joinInterfaceBuilderDispatch } from '../upstream/src/domain/native/nativeInvestigationGraph';
import { objcSwiftMetadataSchema } from '../upstream/src/domain/native/objcSwiftMetadata';
import { parseAppleAssetCatalogRecords, projectAppleAssetCatalogPage } from '../upstream/src/domain/apple/appleAssetCatalog';
import { AnalysisOutputError, AnalysisInputError } from '../upstream/src/domain/analysisErrorCore';
import { jsonValueSchema, type JsonValue } from '../upstream/src/domain/jsonValue';

const hash = z.string().regex(/^[a-f0-9]{64}$/u);
const path = z.string().min(1).max(4096).refine(p => !p.startsWith('/') && !p.split('/').some(c => c === '..' || c === '.' || c === '') && !p.includes('\\'), 'root-relative path');
const encoded = z.string().max(12 * 1024 * 1024);
export const uiInputSchema = z.strictObject({
 targetSHA256: hash, snapshotID: z.string().min(1).max(256),
 documents: z.array(z.strictObject({relativePath:path, archiveSHA256:hash, kind:z.enum(['nib','storyboard_scene']), format:z.enum(['nibArchive','keyedArchiveJSON']), bytesBase64:encoded})).max(64),
 omittedDocuments:z.number().int().min(0).max(1_000_000).default(0),
 omittedCatalogs:z.number().int().min(0).max(1_000_000).default(0),
 metadata:z.strictObject({targetSHA256:hash,snapshotID:z.string().min(1).max(256),value:objcSwiftMetadataSchema}).optional(),
 assetCatalogs:z.array(z.strictObject({path,sha256:hash,captureID:z.string().min(1).max(256),toolSHA256:hash,metadataJSONBase64:encoded,metadataSHA256:hash})).max(64).optional()
});
const DECODE_BUDGET = 32 * 1024 * 1024;
class CheckedBudget extends InterfaceBuilderDecodeBudget {
 override reserve(bytes:number,message:string) { checkpoint(); super.reserve(bytes,message); }
 override tryReserve(bytes:number) { checkpoint(); return super.tryReserve(bytes); }
}
function capturedBytes(base64:string, expected:string, budget:InterfaceBuilderDecodeBudget) {
 // Canonical decoding below validates the alphabet/padding without recursive regex
 // backtracking over multi-megabyte captured payloads.
 const estimated=base64.length / 4 * 3;
 budget.reserve(estimated,'captured byte budget exhausted');
 const bytes=Buffer.from(base64,'base64');
 if(bytes.toString('base64')!==base64)throw new Error('noncanonical base64');
 if(sha256Base64(base64)!==expected)throw new Error('captured bytes hash mismatch');
 return bytes;
}
function capturedJSON(bytes:Uint8Array,budget:InterfaceBuilderDecodeBudget) {
 budget.reserve(bytes.length*6,'decoded JSON expansion budget exhausted');
 const value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
 guardJSON(value); return value;
}

/** Pure captured-data projection; never opens archives, tools, or applications. */
export function uiResources(raw:unknown) {
 guardJSON(raw); const input=uiInputSchema.parse(raw); checkpoint();
 if(input.metadata && (input.metadata.targetSHA256!==input.targetSHA256 || input.metadata.snapshotID!==input.snapshotID))throw new Error('wrong image or snapshot metadata');
 const budget=new CheckedBudget(DECODE_BUDGET);
 const documents:InterfaceBuilderDocumentInput[]=[];
 const coverage:Array<{facet:string,status:string,reason:string|null,examined:number,omitted:number}>=[];
 const seen=new Set<string>();
 for(const document of input.documents) {
  checkpoint();
  if(seen.has(document.relativePath))throw new Error('duplicate archive path'); seen.add(document.relativePath);
  // Integrity failures reject the request, rather than masquerading as malformed content.
  const bytes=capturedBytes(document.bytesBase64,document.archiveSHA256,budget);
  try {
   let decoded:unknown; let omitted=0;
   if(document.format==='nibArchive') {
    const archive=decodeNibArchive(bytes,budget);
    const projection=projectNibArchive(archive,budget,10_000);
    decoded=projection.raw; omitted=projection.omitted;
   } else {
    decoded=capturedJSON(bytes,budget);
    // Validate keyed-archive kind/root before the graph parser's conservative fallback.
    projectKeyedArchive(decoded,{offset:0,limit:1});
   }
   documents.push({relativePath:document.relativePath,archiveSha256:document.archiveSHA256,documentKind:document.kind,raw:decoded});
   coverage.push({facet:document.relativePath,status:omitted?'partial':'complete',reason:omitted?'hierarchy_references_omitted':null,examined:1,omitted});
  } catch(error) {
   if(!(error instanceof TypeError || error instanceof SyntaxError || error instanceof z.ZodError || error instanceof AnalysisOutputError || error instanceof AnalysisInputError))throw error;
   // Cancellation must propagate; it cannot be converted into coverage.
   checkpoint();
   coverage.push({facet:document.relativePath,status:'unsupported',reason:'malformed_or_unsupported_archive',examined:1,omitted:1});
  }
 }
 const limits=interfaceBuilderLimitsSchema.parse({max_documents:64,max_objects:10_000,max_connections:20_000});
 let analysis=buildInterfaceBuilderAnalysis({targetSha256:input.targetSHA256,toolVersion:'macscope-rea-ui/1',documents,limits});
 // Captured class-swap metadata is stronger evidence than a custom class-name
 // substring. Preserve the runtime class for dispatch, while restoring the
 // encoded controller role before the upstream dispatch join.
 analysis={...analysis,graph:{...analysis.graph,nodes:analysis.graph.nodes.map(node=>{
  const values=node.attributes.nibValues;
  if(values && typeof values==='object' && !Array.isArray(values)) {
   const original=(values as Record<string,unknown>).NSOriginalClassName;
   if(original==='NSViewController' || original==='NSWindowController' || original==='UIViewController')return {...node,kind:'view_controller' as const};
  }
  return node;
 })}};
 checkpoint();
 const dispatchCandidates=input.metadata?.value.objc_dispatch_implementations ?? [];
 // Preserve duplicate candidate records and exact addresses, including integers beyond 2^53.
 for(const candidate of dispatchCandidates) {
  for(const address of [candidate.implementation_address,candidate.location.address]) {
   if(address!==null && !/^(?:0x[0-9a-fA-F]+|[0-9]+)$/u.test(address))throw new Error('invalid exact address');
  }
 }
 if(input.metadata) {
  analysis={...analysis,graph:joinInterfaceBuilderDispatch(analysis.graph,input.metadata.value)};
  const metadataCoverage=input.metadata.value.coverage;
  if(metadataCoverage.length===0)coverage.push({facet:'objc_metadata',status:'partial',reason:'metadata_completeness_unspecified',examined:dispatchCandidates.length,omitted:0});
  for(const item of metadataCoverage)coverage.push({facet:'metadata:'+item.facet,status:item.status,reason:item.reason,examined:item.examined,omitted:Math.max(0,item.examined-item.decoded)});
 }
 else coverage.push({facet:'objc_metadata',status:'not_requested',reason:'metadata_unavailable',examined:0,omitted:0});
 coverage.push({facet:'archive_inventory',status:input.omittedDocuments?'partial':'complete',reason:input.omittedDocuments?'archives_omitted':null,examined:input.documents.length,omitted:input.omittedDocuments});
 if(input.omittedCatalogs>0)coverage.push({facet:'asset_catalog_inventory',status:'partial',reason:'catalogs_omitted',examined:input.assetCatalogs?.length??0,omitted:input.omittedCatalogs});
 let assetCatalogs:ReturnType<typeof projectAppleAssetCatalogPage>|null=null;
 const catalogProvenance:Array<{path:string,sha256:string,captureID:string,toolSHA256:string,metadataSHA256:string}>=[];
 if(input.assetCatalogs===undefined)coverage.push({facet:'asset_catalogs',status:'not_requested',reason:'catalog_metadata_unavailable',examined:0,omitted:0});
 else {
  const catalogs=[]; const paths=new Set<string>();
  for(const catalog of input.assetCatalogs) {
   checkpoint(); if(paths.has(catalog.path))throw new Error('duplicate catalog path'); paths.add(catalog.path);
   const bytes=capturedBytes(catalog.metadataJSONBase64,catalog.metadataSHA256,budget);
   try {
    const records=parseAppleAssetCatalogRecords(capturedJSON(bytes,budget));
    if(records.length>10_000)throw new InterfaceBuilderDecodeBudgetExceeded('aggregate_decode_budget_exhausted','catalog record budget exhausted');
    catalogs.push({path:catalog.path,sha256:catalog.sha256,records});
    const {metadataJSONBase64,...provenance}=catalog;catalogProvenance.push(provenance);
    coverage.push({facet:catalog.path,status:'complete',reason:null,examined:records.length,omitted:0});
   } catch(error) {
    if(!(error instanceof TypeError || error instanceof SyntaxError || error instanceof z.ZodError || error instanceof AnalysisOutputError || error instanceof AnalysisInputError))throw error;
    checkpoint(); coverage.push({facet:catalog.path,status:'unsupported',reason:'malformed_catalog_metadata',examined:1,omitted:1});
   }
  }
  assetCatalogs=projectAppleAssetCatalogPage({targetSha256:input.targetSHA256,catalogs,offset:0,limit:10_000});
  // An empty capture set establishes no assertion about catalog existence.
  if(input.assetCatalogs.length===0)coverage.push({facet:'asset_catalogs',status:'not_requested',reason:'no_captured_catalog_metadata',examined:0,omitted:0});
 }
 checkpoint();
 const result={snapshotID:input.snapshotID,analysis,dispatchCandidates,assetCatalogs,catalogProvenance,coverage,decodedBytes:budget.usedBytes};
 guardJSON(result); return result;
}

// Verbatim pure projection selected from REA c29931ce81dc530d2623ec992714a70b1f3e50e4
// src/artifacts/apple/InterfaceBuilderAnalysis.ts:276-550 (MIT); no I/O wrapper copied.
/** Project decoded NIB records into the same bounded graph input as ibtool. */
const projectNibArchive = (
  archive: NibArchiveDocument,
  budget: InterfaceBuilderDecodeBudget,
  maxHierarchyNodes: number,
) => {
  const byId = new Map(archive.objects.map((object) => [object.id, object]));
  const normalizedClassNames = new Map<string, string>();
  const normalizeClassName = (value: string): string => {
    const known = normalizedClassNames.get(value);
    if (known !== undefined) return known;
    const normalized = value.replace(/\0+$/u, "");
    normalizedClassNames.set(value, normalized);
    return normalized;
  };
  const decodedStrings = new Map<number, string | null>();
  const decodedString = (
    objectId: number,
    object: NibArchiveDocument["objects"][number],
  ): string | null => {
    if (decodedStrings.has(objectId))
      return decodedStrings.get(objectId) ?? null;
    const data = object.values["NS.bytes"];
    if (typeof data !== "object" || data === null || Array.isArray(data)) {
      decodedStrings.set(objectId, null);
      return null;
    }
    const encoded = data.$nib_data_base64;
    if (typeof encoded !== "string") {
      decodedStrings.set(objectId, null);
      return null;
    }
    budget.reserve(
      64 + encoded.length * 2,
      "NIBArchive string projection exceeds the aggregate Interface Builder decode budget",
    );
    const value = Buffer.from(encoded, "base64").toString("utf8");
    decodedStrings.set(objectId, value);
    return value;
  };
  let projectedFields = 0;
  for (const object of archive.objects)
    projectedFields += Object.keys(object.values).length;
  budget.reserve(
    archive.objects.length * 128 + projectedFields * 128,
    "NIBArchive graph projection exceeds the aggregate Interface Builder decode budget",
  );
  budget.reserve(
    archive.classes.length * 96,
    "NIBArchive class projection exceeds the aggregate Interface Builder decode budget",
  );
  const dereference = (value: JsonValue | undefined): JsonValue | undefined => {
    if (typeof value !== "object" || value === null || Array.isArray(value))
      return value;
    const encodedData = value.$nib_data_base64;
    if (typeof encodedData === "string") {
      budget.reserveBase64JsonStringOccurrence(encodedData);
      return value;
    }
    const ref = value.$nib_object_ref;
    if (typeof ref !== "number") return value;
    const target = byId.get(ref);
    if (target === undefined) return undefined;
    if (normalizeClassName(target.class_name) === "NSString") {
      const string = decodedString(ref, target);
      if (string !== null) {
        budget.reserveJsonStringOccurrence(string);
        return string;
      }
    }
    return { objectID: String(ref) };
  };
  const referencedString = (value: JsonValue | undefined): string | null => {
    if (typeof value !== "object" || value === null || Array.isArray(value))
      return null;
    const ref = value.$nib_object_ref;
    if (typeof ref !== "number") return null;
    const target = byId.get(ref);
    if (
      target === undefined ||
      normalizeClassName(target.class_name) !== "NSString"
    )
      return null;
    const string = decodedString(ref, target);
    if (string === null) return null;
    budget.reserveJsonStringOccurrence(string);
    return string;
  };
  const runtimeClasses = new Map<number, string | null>();
  const runtimeClass = (objectId: number): string | null => {
    if (runtimeClasses.has(objectId))
      return runtimeClasses.get(objectId) ?? null;
    const object = byId.get(objectId);
    if (object === undefined) return null;
    const storedClass = normalizeClassName(object.class_name);
    const resolvedClass =
      storedClass === "NSClassSwapper"
        ? (referencedString(object.values.NSClassName) ?? storedClass)
        : storedClass === "UIClassSwapper"
          ? (referencedString(object.values.UIClassName) ?? storedClass)
          : storedClass;
    runtimeClasses.set(objectId, resolvedClass);
    return resolvedClass;
  };
  const objects = Object.fromEntries(
    archive.objects
      .filter((object) => {
        const name = runtimeClass(object.id) ?? "";
        return !/^(?:NSObject|NSIBObjectData|NSString|NSMutableString|NSNumber|NSArray|NSMutableArray|NSSet|NSMutableSet|NSDictionary|NSMutableDictionary|NSApplication|NSNib.*Connector|UIRuntime\w*Connection)$/u.test(
          name,
        );
      })
      .map((object) => {
        const className =
          runtimeClass(object.id) ?? normalizeClassName(object.class_name);
        budget.reserveJsonStringOccurrence(className);
        let name = className;
        for (const [key, value] of Object.entries(object.values)) {
          if (
            !/(?:title|label|identifier|accessibility|name|contents)/iu.test(
              key,
            )
          )
            continue;
          const resolved = dereference(value);
          if (typeof resolved !== "string") continue;
          name = resolved;
          break;
        }
        budget.reserveJsonStringOccurrence(name);
        return [
          String(object.id),
          {
            customClass: className,
            label: name,
            objectID: String(object.id),
            nibValues: Object.fromEntries(
              Object.entries(object.values).map(([key, value]) => {
                budget.reserveJsonPropertyNameOccurrence(key);
                return [key, dereference(value) ?? null];
              }),
            ),
          },
        ];
      }),
  );
  const connections: Record<string, JsonValue[]> = {};
  const hierarchy: NibHierarchyNode[] = [];
  const reference = (value: JsonValue | undefined): number | null => {
    if (typeof value !== "object" || value === null || Array.isArray(value))
      return null;
    return typeof value.$nib_object_ref === "number"
      ? value.$nib_object_ref
      : null;
  };
  for (const object of archive.objects) {
    const className = normalizeClassName(object.class_name);
    // AppKit connectors use NS-prefixed keys; UIKit's runtime outlet and
    // event connections use UI-prefixed keys with the same roles.
    const uiKit = /^UIRuntime\w*Connection$/u.test(className);
    if (!uiKit && !className.includes("Connector")) continue;
    const values = object.values;
    const source = reference(uiKit ? values.UISource : values.NSSource);
    if (source === null) continue;
    const destination = reference(
      uiKit ? values.UIDestination : values.NSDestination,
    );
    const label = referencedString(uiKit ? values.UILabel : values.NSLabel);
    const type = className.includes("Outlet")
      ? "outlet"
      : className.includes("Control") || className.includes("Event")
        ? "action"
        : className;
    budget.reserveJsonStringOccurrence(type);
    const eventMask = values.UIEventMask;
    // The source is the outlet owner or the sending control; the destination
    // is the outlet value or the action target, and a nil target is the
    // first responder.
    (connections[String(source)] ??= []).push({
      type,
      "destination-id": destination === null ? null : String(destination),
      label,
      source_id: String(source),
      archive_object_id: String(object.id),
      ...(typeof eventMask === "number" ? { ui_event_mask: eventMask } : {}),
    });
  }
  let hierarchyOmitted = 0;
  let hierarchyNodeCount = 0;
  const hierarchyFor = (
    objectId: number,
    seen: Set<number>,
    depth: number,
  ): NibHierarchyNode | null => {
    if (depth > 32 || seen.has(objectId)) {
      hierarchyOmitted += 1;
      return null;
    }
    if (hierarchyNodeCount >= maxHierarchyNodes) {
      hierarchyOmitted += 1;
      return null;
    }
    if (!budget.tryReserve(128)) {
      hierarchyOmitted += 1;
      return null;
    }
    const object = byId.get(objectId);
    if (object === undefined) {
      hierarchyOmitted += 1;
      return null;
    }
    hierarchyNodeCount += 1;
    const nextSeen = new Set(seen).add(objectId);
    const children: NibHierarchyNode[] = [];
    for (const [key, value] of Object.entries(object.values)) {
      if (!/(?:subviews|contentview|childviewcontrollers|view)$/iu.test(key))
        continue;
      const direct = reference(value);
      if (direct === null) continue;
      const target = byId.get(direct);
      if (target === undefined) {
        hierarchyOmitted += 1;
        continue;
      }
      if (/array|set/iu.test(target.class_name)) {
        for (const candidate of Object.values(target.values)) {
          const child = reference(candidate);
          const nested =
            child === null ? null : hierarchyFor(child, nextSeen, depth + 1);
          if (nested !== null) children.push(nested);
        }
      } else {
        const nested = hierarchyFor(direct, nextSeen, depth + 1);
        if (nested !== null) children.push(nested);
      }
    }
    return { objectID: String(objectId), children };
  };
  const ibData = archive.objects.find(
    ({ class_name }) => normalizeClassName(class_name) === "NSIBObjectData",
  );
  const rootId = reference(ibData?.values.NSRoot);
  const hierarchyRoots = rootId === null ? [] : [rootId];
  for (const hierarchyRoot of hierarchyRoots) {
    const root = hierarchyFor(hierarchyRoot, new Set(), 0);
    if (root !== null) hierarchy.push(root);
  }
  const viewHierarchy = projectNibViewHierarchy(
    archive.objects,
    new Set(Object.keys(objects).map(Number)),
    () => budget.tryReserve(128),
    maxHierarchyNodes,
  );
  const merged = mergeNibHierarchies(
    hierarchy,
    viewHierarchy.hierarchy ?? [],
    () => budget.tryReserve(96),
    maxHierarchyNodes,
  );
  return {
    omitted: viewHierarchy.omitted + hierarchyOmitted + merged.omitted,
    raw: jsonValueSchema.parse({
      "com.apple.ibtool.document.objects": objects,
      "com.apple.ibtool.document.connections": connections,
      "com.apple.ibtool.document.hierarchy": merged.hierarchy,
      "com.apple.ibtool.document.classes": Object.fromEntries(
        archive.classes.map((name) => {
          const className = normalizeClassName(name);
          budget.reserveJsonPropertyNameOccurrence(className);
          return [className, {}];
        }),
      ),
    }),
  };
};

