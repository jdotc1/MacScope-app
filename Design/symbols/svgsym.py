import re, sys
def groups(path):
    s=open(path).read()
    out={}
    for w in ("Ultralight-S","Regular-S","Black-S"):
        m=re.search(r'<g id="%s" transform="matrix\(1 0 0 1 ([\d.\-]+) ([\d.\-]+)\)">(.*?)</g>'%w, s, re.S)
        paths=re.findall(r'<path class="([^"]*)" d="([^"]*)"', m.group(3))
        out[w]=(float(m.group(1)),float(m.group(2)),paths)
    margins={k:float(v) for k,v in re.findall(r'id="((?:left|right)-margin-[A-Za-z]+-S)"[^>]*x1="([\d.\-]+)"', s)}
    return s,out,margins
def nums(d): return [float(x) for x in re.findall(r'-?\d*\.?\d+(?:e-?\d+)?', d)]
def bbox(d):
    n=nums(d); xs=n[0::2]; ys=n[1::2]; return (min(xs),min(ys),max(xs),max(ys))
def curve_bbox(d):
    """The bounds of the drawn outline (cubics sampled), not of its control points."""
    toks=re.findall(r'[MLCZ]|-?\d*\.?\d+(?:e-?\d+)?', d)
    xs=[]; ys=[]; i=0; cur=(0.0,0.0); cmd=None
    while i < len(toks):
        t=toks[i]
        if t in 'MLCZ': cmd=t; i+=1
        if cmd=='Z': continue
        if cmd in 'ML':
            cur=(float(toks[i]),float(toks[i+1])); i+=2; xs.append(cur[0]); ys.append(cur[1])
        elif cmd=='C':
            v=[float(x) for x in toks[i:i+6]]; i+=6
            p0=cur; c1=(v[0],v[1]); c2=(v[2],v[3]); p1=(v[4],v[5])
            for k in range(21):
                u=k/20; a=(1-u)**3; b=3*(1-u)**2*u; c=3*(1-u)*u*u; e=u**3
                xs.append(a*p0[0]+b*c1[0]+c*c2[0]+e*p1[0]); ys.append(a*p0[1]+b*c1[1]+c*c2[1]+e*p1[1])
            cur=p1
    return (min(xs),min(ys),max(xs),max(ys))
def npts(d): return len(re.findall(r'[MLCQZ]', d)), len(nums(d))
if __name__=="__main__":
    for f in sys.argv[1:]:
        s,g,mg=groups(f); print("==",f, {k:round(v,1) for k,v in mg.items()})
        for w,(x,y,paths) in g.items():
            print(" ",w, [ (c.split()[0], tuple(round(v,1) for v in bbox(d)), npts(d)) for c,d in paths])
