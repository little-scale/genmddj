#!/usr/bin/env python3
# gen_factory_bank.py — one-time authoring of the 32-patch FM factory bank.
# Emits the asm dc.b block that lives inline as `fm_factory:` in src/main.asm
# (behind the GMINSTR0 locator). The LIVE source of truth is that inline block +
# the browser patcher (user-tools/genmddj-instrument-patcher.html) which edits the
# bank in a finished .bin. Re-run only to regenerate from scratch. Ops are given in
# logical OP1..OP4 order; the record stores register-slot order [OP1,OP3,OP2,OP4].

# Author the 32-patch FM factory bank. Ops are given in LOGICAL OP1..OP4 order;
# the record stores them in register-slot order [OP1,OP3,OP2,OP4] (slot1<->slot2 swap).
# op = [MUL,DT,TL,RS,AR,AM,D1,D2,RR,SL]
def P(name, algo, fb, ops, vol=15, pan=3, ams=0, fms=0, hld=15):
    return (name, algo, fb, pan, ams, fms, hld, vol, ops)

# carrier_mask = [08,08,08,08,0C,0E,0E,0F]; carriers want low TL, mods set brightness.
INIT = [[1,0,0,0,31,0,0,0,5,0],[0]*10,[0]*10,[0]*10]  # algo7 single sine carrier (slot0)

P0=[[1,7,35,1,31,0,5,2,1,1],[3,3,38,1,31,0,5,2,1,1],[13,0,45,2,25,0,5,2,1,1],[1,0,0,2,20,0,7,2,6,10]]
patches = [
 P("GRANDPNO",2,6,P0),                                                   # 0 the verified Sega grand piano
 P("E.PIANO", 5,4,[[14,0,40,1,31,0,10,4,4,2],[1,0,32,1,31,0,6,3,4,3],[1,0,8,1,31,0,8,4,5,2],[1,0,0,1,28,0,9,4,6,4]]),
 P("SYN.BASS",0,5,[[1,0,30,1,31,0,12,0,8,0],[0,0,0,0,0,0,0,0,0,0],[0,0,0,0,0,0,0,0,0,0],[0,0,2,1,31,0,10,4,9,2]]),
 P("PICKBASS",2,4,[[2,0,28,1,31,0,14,5,8,3],[1,3,34,1,31,0,12,5,8,3],[3,0,40,1,31,0,12,5,8,3],[1,0,4,1,31,0,12,6,9,2]]),
 P("BRASS",   2,5,[[1,0,30,1,18,0,8,0,6,0],[1,0,36,1,18,0,8,0,6,0],[1,1,33,1,18,0,8,0,6,0],[1,0,6,1,16,0,6,0,7,0]]),
 P("STRINGS", 4,3,[[2,1,42,0,12,0,6,0,8,0],[1,0,10,0,12,0,6,0,8,0],[2,2,44,0,12,0,6,0,8,0],[1,0,8,0,11,0,6,0,9,0]]),
 P("ORGAN",   7,0,[[1,0,8,0,31,0,0,0,8,0],[2,0,14,0,31,0,0,0,8,0],[4,0,18,0,31,0,0,0,8,0],[1,0,4,0,31,0,0,0,8,0]]),
 P("SQR.LEAD",2,7,[[1,0,28,1,31,0,6,0,7,0],[1,0,30,1,31,0,6,0,7,0],[2,0,30,1,31,0,6,0,7,0],[1,0,4,1,31,0,5,0,7,0]]),
 P("SAWLEAD", 0,4,[[1,0,26,1,31,0,5,0,7,0],[0]*10,[0]*10,[1,0,2,1,31,0,4,0,7,0]]),
 P("BELL",    4,2,[[7,1,38,0,31,0,14,4,5,1],[1,0,12,0,31,0,16,5,5,2],[14,3,40,0,31,0,14,4,5,1],[1,0,10,0,31,0,16,6,5,3]]),
 P("MARIMBA", 5,3,[[1,0,34,0,31,0,18,0,8,0],[7,0,16,0,31,0,18,0,8,0],[1,0,16,0,31,0,18,0,8,0],[14,0,14,0,31,0,18,0,8,0]]),
 P("VIBES",   5,1,[[7,1,30,0,31,0,12,3,6,2],[14,2,18,0,31,0,12,3,6,2],[1,0,18,0,31,0,12,3,6,2],[1,0,12,0,31,0,12,3,7,2]]),
 P("SYN.PAD", 4,2,[[2,1,40,0,8,0,5,0,9,0],[1,3,16,0,8,0,5,0,9,0],[3,2,42,0,8,0,5,0,9,0],[1,0,12,0,7,0,5,0,10,0]]),
 P("CLAV",    2,6,[[2,0,30,2,31,0,16,6,8,4],[1,3,32,2,31,0,16,6,8,4],[6,0,38,2,31,0,16,6,8,4],[1,0,6,2,31,0,18,7,9,3]]),
 P("HARPSI",  5,4,[[4,0,32,1,31,0,16,4,7,2],[1,0,18,1,31,0,16,4,7,2],[8,0,34,1,31,0,16,4,7,2],[1,0,12,1,31,0,18,5,8,2]]),
 P("FLUTE",   0,0,[[1,0,40,0,20,0,6,0,7,0],[0]*10,[0]*10,[1,0,8,0,18,0,5,0,8,0]]),
 P("TRUMPET", 2,5,[[1,0,28,1,16,0,8,0,6,0],[1,1,34,1,16,0,8,0,6,0],[2,0,32,1,16,0,8,0,6,0],[1,0,6,1,14,0,6,0,7,0]]),
 P("SYNBRASS",4,4,[[1,0,32,0,16,0,8,0,7,0],[1,0,10,0,16,0,8,0,7,0],[1,1,34,0,16,0,8,0,7,0],[1,0,8,0,15,0,7,0,8,0]]),
 P("FRETLESS",2,3,[[1,0,30,1,31,0,12,4,8,3],[2,3,36,1,31,0,12,4,8,3],[3,0,40,1,31,0,12,4,8,3],[1,0,4,1,31,0,11,5,9,2]]),
 P("WOODBASS",2,2,[[1,0,32,1,31,0,16,6,9,5],[1,0,38,1,31,0,16,6,9,5],[2,0,42,1,31,0,16,6,9,5],[1,0,6,1,31,0,18,7,10,4]]),
]
# fill to 32 with INIT (basic sine — a clean starting point to edit in the patcher)
while len(patches) < 32:
    patches.append(P("INIT", 7, 0, [r[:] for r in INIT]))

def chk(v,lo,hi,ctx):
    assert lo<=v<=hi, f"{ctx}: {v} out of [{lo},{hi}]"
    return v
out=['fm_marker:  dc.b "GMINSTR0"        ; factory FM bank locator for the browser patcher','            even',
     'fm_factory:                       ; 32 x INSTR_SIZE (64) factory instrument patches']
for i,(name,algo,fb,pan,ams,fms,hld,vol,ops) in enumerate(patches):
    chk(algo,0,7,f"{name} algo"); chk(fb,0,7,"fb")
    rec_ops=[ops[0],ops[2],ops[1],ops[3]]   # logical OP1,OP2,OP3,OP4 -> record slots OP1,OP3,OP2,OP4
    hdr=[0,algo,fb,pan,ams,fms,hld,vol]
    out.append(f'    dc.b {algo}<<0|0,0,0,0,0,0,0,0  ; placeholder')  # will replace below
    out[-1]=f'    dc.b 0, {algo}, {fb}, {pan}, {ams}, {fms}, {hld}, {vol}   ; {i:2d} {name}'
    sl=["S1","S3","S2","S4"]
    for k,op in enumerate(rec_ops):
        for j,(v,rng) in enumerate(zip(op,[(0,15),(0,7),(0,127),(0,3),(0,31),(0,1),(0,31),(0,31),(0,15),(0,15)])):
            chk(v,rng[0],rng[1],f"{name} slot{k} p{j}")
        out.append('    dc.b '+", ".join(str(x) for x in op)+f'  ; slot{k} {sl[k]}')
    out.append('    dc.b $FF, 1, 0, 0, 0, 0        ; i_tbl i_tbs kit gain rate tsp (48-53)')
    nm=(name+" "*8)[:8]
    out.append('    dc.b "'+nm+'"        ; i_name (54-61)')
    out.append('    dc.b 0, 0                      ; reserved 62-63')
out.append('    even')
block="\n".join(out)+"\n"
open("/tmp/fm_factory.inc","w").write(block)
print(f"generated {len(patches)} patches, {sum(1 for p in patches if p[0]!='INIT')} named")
print("names:", ", ".join(p[0] for p in patches[:20]))
