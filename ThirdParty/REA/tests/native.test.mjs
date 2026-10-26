import assert from 'node:assert/strict';
export async function run(analyze) {
 const slice={architecture:'arm64',slice_offset:0,slice_size:32,cpu_type:16777228,cpu_subtype:0,fat_cpu_type:null,fat_cpu_subtype:null,fat_alignment_exponent:null,file_type:'execute',file_type_code:2,platform:1,platforms:[1],install_name:null,dependencies:[],rpaths:[],dyld_environment:[],code_signature_present:false};
 const input={inventoryComplete:true,subject:{name:'Example.app',format:'directory'},entries:[{path:'Contents',kind:'directory'},{path:'Contents/MacOS',kind:'directory'},{path:'Contents/MacOS/main',kind:'file'}],images:[{path:'Contents/MacOS/main',facts:{status:'parsed',slices:[slice]}}],roots:['Contents/MacOS/main']};
 const good=await analyze({operation:'nativeApplication',input});assert.equal(good.ok,true,JSON.stringify(good));assert.deepEqual(good.result.applicationRoots,['.']);assert.equal(good.result.bundles[0].role,'application');assert.equal(good.result.trace.roots.length,1);
 const dependency={command:'LC_LOAD_DYLIB',encoding:'dylib_command',install_name:'@rpath/libA.dylib',weak:false,upward:false,reexport:false,delayed_init:false,current_version:'1.0.0',compatibility_version:'1.0.0'};
 const processes=JSON.parse(JSON.stringify(input));
 processes.entries.push({path:'Contents/Helpers',kind:'directory'},{path:'Contents/Helpers/helper',kind:'file'},{path:'Contents/Frameworks',kind:'directory'},{path:'Contents/Frameworks/libA.dylib',kind:'file'});
 processes.images[0].facts.slices[0].dependencies=[dependency];processes.images[0].facts.slices[0].rpaths=['@loader_path/../Frameworks'];
 processes.images.push({path:'Contents/Helpers/helper',facts:{status:'parsed',slices:[{...slice,dependencies:[dependency],rpaths:['@loader_path/Frameworks']}]}},{path:'Contents/Frameworks/libA.dylib',facts:{status:'parsed',slices:[{...slice,file_type:'dylib',file_type_code:6,install_name:'@rpath/libA.dylib'}]}});
 processes.roots.push('Contents/Helpers/helper');
 const independent=await analyze({operation:'nativeApplication',input:processes});assert.equal(independent.ok,true,JSON.stringify(independent));
 const edges=independent.result.trace.edges;
 assert.equal(edges.find(e=>e.root==='Contents/MacOS/main').resolution.status,'resolved');
 const helper=edges.find(e=>e.root==='Contents/Helpers/helper');assert.equal(helper.resolution.status,'unresolved');
 assert.ok(helper.candidates.every(c=>c.rpath_owner!=='Contents/MacOS/main'),'helper cannot inherit another executable root rpaths');
 const clone=()=>JSON.parse(JSON.stringify(input));
 const incomplete=clone();incomplete.inventoryComplete=false;assert.equal((await analyze({operation:'nativeApplication',input:incomplete})).ok,false);
 const unsafe=clone();unsafe.entries[0].path='../outside';assert.equal((await analyze({operation:'nativeApplication',input:unsafe})).ok,false);
 const duplicate=clone();duplicate.entries.push(duplicate.entries[0]);assert.equal((await analyze({operation:'nativeApplication',input:duplicate})).ok,false);
 const large=clone();large.images[0].facts.slices[0].slice_offset=9007199254740992;assert.equal((await analyze({operation:'nativeApplication',input:large})).ok,false);
 const unknown=clone();unknown.images=[];const missing=await analyze({operation:'nativeApplication',input:unknown});assert.equal(missing.ok,true);assert.equal(missing.result.trace.roots.length,0);
}
