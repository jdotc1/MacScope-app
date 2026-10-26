#!/usr/bin/env python3
"""Offline fail-closed verification of exact canonical tracked REA resource inputs."""
import hashlib,json,pathlib,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[2]
PREFIX='ThirdParty/REA/'
def sha(data):return hashlib.sha256(data).hexdigest()
def blob(relative):
    path=ROOT/relative
    if path.is_symlink() or not path.is_file():raise ValueError('unsafe/missing input '+relative)
    try:data=subprocess.check_output(['git','cat-file','blob','HEAD:'+relative],cwd=ROOT,stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        if (ROOT/'.git').exists():raise ValueError('input not committed '+relative)
        # Gitless sealed source export: canonical bytes were exported by qualification owner.
        data=path.read_bytes()
    if path.read_bytes()!=data:raise ValueError('checkout differs from canonical Git blob '+relative)
    return data
try:
    source=json.loads(blob(PREFIX+'SOURCE_MANIFEST.json'))
    if source['commit']!='c29931ce81dc530d2623ec992714a70b1f3e50e4':raise ValueError('unreviewed source pin')
    if sha(blob(PREFIX+'LICENSE'))!=source['license']['sha256']:raise ValueError('REA license drift')
    for item in source['files']:
        data=blob(PREFIX+'upstream/'+item['path'])
        if sha(data)!=item['sha256']:raise ValueError('upstream hash '+item['path'])
        if hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()!=item['blob']:raise ValueError('upstream Git blob '+item['path'])
    manifest=json.loads(blob(PREFIX+'generated/RESOURCE_MANIFEST.json'))
    for item in manifest['identityPreimage']:
        if sha(blob((PREFIX+item['path']) if not item['path'].startswith('Scripts/') else item['path']))!=item['sha256']:raise ValueError('implementation input identity mismatch')
    if sha(json.dumps(manifest['identityPreimage'],separators=(',',':'),ensure_ascii=False).encode())!=manifest['implementationIdentity']:raise ValueError('implementation identity mismatch')
    for item in manifest['inputs']+[manifest['resource']]:
        if not item['path'].startswith(PREFIX) or '..' in pathlib.PurePosixPath(item['path']).parts:raise ValueError('unsafe receipt path')
        data=blob(item['path'])
        if sha(data)!=item['sha256'] or len(data)!=item['bytes']:raise ValueError('consumed bytes mismatch '+item['path'])
    deps=json.loads(blob(PREFIX+'DEPENDENCIES.json'))
    lock=json.loads(blob(PREFIX+'package-lock.json'))
    for dep in deps['runtimePackages']:
        entry=lock['packages']['node_modules/'+dep['package']]
        if entry['version']!=dep['version'] or entry['integrity']!=dep['integrity']:raise ValueError('dependency identity mismatch')
        for name in dep['licenseFiles']:blob(PREFIX+name)
    identity=blob(PREFIX+'generated/REAEmbeddedIdentity.swift').decode()
    if manifest['resource']['sha256'] not in identity or manifest['implementationIdentity'] not in identity:raise ValueError('Swift resource identity mismatch')
    print(json.dumps({'ok':True,'upstreamCommit':source['commit'],'resourceSHA256':manifest['resource']['sha256'],'inputs':len(manifest['inputs']),'dependencyNetworkUsed':False}))
except (ValueError,KeyError,OSError,json.JSONDecodeError) as error:
    print('REA verification rejected: '+str(error),file=sys.stderr);sys.exit(1)
