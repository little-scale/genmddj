#!/usr/bin/env python3
"""Draw the 8 YM2612 FM algorithm routing diagrams and convert to MD 4bpp tiles.

  makealgos.py <tiles.bin> <maps.bin> <out.i>

Each diagram is ALGO_W x ALGO_H tiles. Operators are small numbered boxes;
arrows show modulation; carriers get an output arrow. Tiles are deduplicated
across all 8 diagrams; each diagram is a row-major tilemap of local indices.
Foreground pixels -> colour index 1 (renders in the palette's c1, like the font).
"""
import sys

ALGO_W, ALGO_H = 12, 5            # tiles per diagram (1x, half size)
W, H = ALGO_W * 8, ALGO_H * 8                 # render pixels (96 x 40)
BW, BH = 13, 9                    # operator box size

# 3x5 digit glyphs for the operator labels (1..4)
DIG = {
    1: ["010", "110", "010", "010", "111"],
    2: ["110", "001", "010", "100", "111"],
    3: ["110", "001", "010", "001", "110"],
    4: ["101", "101", "111", "001", "001"],
}

# per-algorithm operator grid cell (col 0-3, row 0-2), connections, outputs
# conn: (from_op, to_op); out: op -> direction ('r' right, 'd' down)
ALGOS = [
    # 0: serial 1->2->3->4
    dict(pos={1:(0,1),2:(1,1),3:(2,1),4:(3,1)}, conn=[(1,2),(2,3),(3,4)], out={4:'r'}),
    # 1: (1,2)->3->4
    dict(pos={1:(0,0),2:(0,2),3:(1,1),4:(2,1)}, conn=[(1,3),(2,3),(3,4)], out={4:'r'}),
    # 2: 1->4 ; 2->3->4
    dict(pos={1:(1,0),2:(0,2),3:(1,2),4:(2,1)}, conn=[(1,4),(2,3),(3,4)], out={4:'r'}),
    # 3: 1->2->4 ; 3->4
    dict(pos={1:(0,0),2:(1,0),3:(1,2),4:(2,1)}, conn=[(1,2),(2,4),(3,4)], out={4:'r'}),
    # 4: 1->2 ; 3->4   (2,4 carriers)
    dict(pos={1:(0,0),2:(1,0),3:(0,2),4:(1,2)}, conn=[(1,2),(3,4)], out={2:'r',4:'r'}),
    # 5: 1->2,3,4
    dict(pos={1:(0,1),2:(1,0),3:(1,1),4:(1,2)}, conn=[(1,2),(1,3),(1,4)], out={2:'r',3:'r',4:'r'}),
    # 6: 1->2 ; 3 ; 4
    dict(pos={1:(0,0),2:(1,0),3:(1,1),4:(1,2)}, conn=[(1,2)], out={2:'r',3:'r',4:'r'}),
    # 7: all parallel carriers
    dict(pos={1:(0,0),2:(1,0),3:(2,0),4:(3,0)}, conn=[], out={1:'d',2:'d',3:'d',4:'d'}),
]

COLX = [2, 26, 50, 74]           # grid-col x (box left)
ROWY = [2, 15, 28]               # grid-row y (box top)


def box_xy(cell):
    c, r = cell
    return COLX[c], ROWY[r]


def render(algo):
    px = [[0] * W for _ in range(H)]

    def pset(x, y):
        if 0 <= x < W and 0 <= y < H:
            px[y][x] = 1

    def hline(x0, x1, y):
        for x in range(min(x0, x1), max(x0, x1) + 1):
            pset(x, y)

    def vline(x, y0, y1):
        for y in range(min(y0, y1), max(y0, y1) + 1):
            pset(x, y)

    def box(x, y, n):
        for i in range(BW):
            pset(x + i, y); pset(x + i, y + BH - 1)
        for j in range(BH):
            pset(x, y + j); pset(x + BW - 1, y + j)
        gx, gy = x + (BW - 3) // 2, y + (BH - 5) // 2
        for j, row in enumerate(DIG[n]):
            for i, ch in enumerate(row):
                if ch == '1':
                    pset(gx + i, gy + j)

    def arrowhead_r(x, y):
        pset(x, y); pset(x - 1, y - 1); pset(x - 1, y + 1)

    def arrowhead_d(x, y):
        pset(x, y); pset(x - 1, y - 1); pset(x + 1, y - 1)

    def connect(a, b):
        ax, ay = box_xy(algo['pos'][a]); bx, by = box_xy(algo['pos'][b])
        ax2, ay2 = ax + BW, ay + BH // 2            # exit right-middle of A
        bx0, by0 = bx, by + BH // 2                 # enter left-middle of B
        # route: right from A, vertical to B's row, into B's left
        midx = (ax2 + bx0) // 2
        hline(ax2, midx, ay2)
        vline(midx, ay2, by0)
        hline(midx, bx0 - 1, by0)
        arrowhead_r(bx0 - 1, by0)

    def output(n, d):
        x, y = box_xy(algo['pos'][n])
        if d == 'r':
            hline(x + BW, x + BW + 6, y + BH // 2)
            arrowhead_r(x + BW + 6, y + BH // 2)
        else:
            vline(x + BW // 2, y + BH, y + BH + 5)
            arrowhead_d(x + BW // 2, y + BH + 5)

    for n, cell in algo['pos'].items():
        box(*box_xy(cell), n)
    for a, b in algo['conn']:
        connect(a, b)
    for n, d in algo['out'].items():
        output(n, d)
    hline(0, W - 1, 0); hline(0, W - 1, H - 1)     # 1px frame around the diagram
    vline(0, 0, H - 1); vline(W - 1, 0, H - 1)
    return px


def main():
    out_tiles, out_maps, out_inc = sys.argv[1:4]
    uniq, index, maps = [], {}, []
    for algo in ALGOS:
        px = render(algo)
        tmap = []
        for ty in range(ALGO_H):
            for tx in range(ALGO_W):
                tile = bytearray(32)
                for row in range(8):
                    for col in range(8):
                        if px[ty * 8 + row][tx * 8 + col]:
                            bi = row * 4 + (col >> 1)
                            tile[bi] |= 0x01 if (col & 1) else 0x10
                key = bytes(tile)
                if key not in index:
                    index[key] = len(uniq); uniq.append(key)
                tmap.append(index[key])
        maps.append(tmap)
    with open(out_tiles, "wb") as f:
        for t in uniq:
            f.write(t)
    with open(out_maps, "wb") as f:
        for m in maps:
            f.write(bytes(m))
    with open(out_inc, "w") as f:
        f.write(f"ALGO_W equ {ALGO_W}\nALGO_H equ {ALGO_H}\n")
        f.write(f"ALGO_NTILES equ {len(uniq)}\nALGO_MAPSZ equ {ALGO_W*ALGO_H}\n")
    assert len(uniq) <= 256
    print(f"algos: {ALGO_W}x{ALGO_H}, {len(uniq)} unique tiles, {len(maps)} maps")


if __name__ == "__main__":
    main()
