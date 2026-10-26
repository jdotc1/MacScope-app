#!/usr/bin/env python3
"""Prove the vertical mask factorization against the original dilation.

Every single predicate bit is checked for every legal SVL and element width;
random combinations additionally exercise OR/multiplication interactions.
This mathematical test supplements, not replaces, emitted-p-code execution.
"""
import argparse,json,pathlib,random
BITS=2048;FULL=(1<<BITS)-1
MASKS={h:sum(((1<<h)-1)<<i for i in range(0,BITS,8*h)) for h in [1,2,4,8,16,32,64,128]}
def old(pg,cur,b):
 active=(1<<cur)-1;spacing=sum(1<<i for i in range(0,256,b));x=pg&active&spacing
 for h in [128,64,32,16,8,4,2,1]:x=(x|(x<<(7*h)))&MASKS[h]
 return (x*((1<<(8*b))-1))&FULL

def factored(pg,cur,b):
 selected=pg&(((1<<cur)-1)//((1<<b)-1))
 if b>=8:return sum((0-((selected>>(e*b))&255)&((1<<(8*b))-1))<<(e*b*8) for e in range(256//b))
 x=selected
 for h in [128,64,32,16,8,4,2,1]:
  if h>=b:x=(x|(x<<(7*h)))&MASKS[h]
 return (x*((1<<(8*b))-1))&FULL

def main():
 p=argparse.ArgumentParser();p.add_argument('--report',required=True,type=pathlib.Path);a=p.parse_args();rng=random.Random(0x435031424d41534b);counts={};total=0
 for b in [1,2,4,8,16]:
  count=0
  for cur in range(16,257,16):
   active=(1<<cur)-1;assert active//((1<<b)-1)==sum(1<<i for i in range(0,cur,b))
   for pg in [0,(1<<256)-1]+[1<<i for i in range(256)]+[rng.getrandbits(256) for _ in range(128)]:
    assert old(pg,cur,b)==factored(pg,cur,b),(b,cur,hex(pg));count+=1
  counts[str(b)]=count;total+=count
 result={'scope':__doc__,'allLegalSVLBytes':list(range(16,257,16)),'perElementBytes':counts,'comparisons':total,'PASS':total,'FAIL':0,'seed':'0x435031424d41534b'};a.report.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
