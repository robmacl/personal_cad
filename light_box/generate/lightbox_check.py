"""Check the generated light box parts against the mock corner, from exported STL meshes.

    python lightbox_check.py <dir with lb_*.STL> <output png>

lightbox_generate.ps1 -ImgDir <dir> writes the STL files (hand A parts and lb_mock_corner).
Prints the overlap volume between each pair (sampled on a grid; 0 means clear, touching faces do not
count) and draws cross-sections. Rigid check only: nothing here knows about flex or tolerance.
"""
import sys, os, struct
import numpy as np
from PIL import Image, ImageDraw

def load(path):
    data = open(path, 'rb').read()
    n = struct.unpack_from('<I', data, 80)[0]
    dt = np.dtype([('n', '<f4', 3), ('v', '<f4', (3, 3)), ('a', '<u2')])
    return np.frombuffer(data, dtype=dt, count=n, offset=84)['v'].astype(float)

def inside(tris, pts):
    """ray cast along +z"""
    a, b, c = tris[:, 0, :2], tris[:, 1, :2], tris[:, 2, :2]
    den = (b[:, 1] - c[:, 1]) * (a[:, 0] - c[:, 0]) + (c[:, 0] - b[:, 0]) * (a[:, 1] - c[:, 1])
    ok = np.abs(den) > 1e-12
    a, b, c, den, t = a[ok], b[ok], c[ok], den[ok], tris[ok]
    res = np.zeros(len(pts), bool)
    step = max(1, 4000000 // max(1, len(t)))
    for i0 in range(0, len(pts), step):
        q = pts[i0:i0 + step]
        l1 = ((b[:, 1] - c[:, 1])[None] * (q[:, None, 0] - c[None, :, 0]) + (c[:, 0] - b[:, 0])[None] * (q[:, None, 1] - c[None, :, 1])) / den[None]
        l2 = ((c[:, 1] - a[:, 1])[None] * (q[:, None, 0] - c[None, :, 0]) + (a[:, 0] - c[:, 0])[None] * (q[:, None, 1] - c[None, :, 1])) / den[None]
        l3 = 1 - l1 - l2
        hit = (l1 > 0) & (l2 > 0) & (l3 > 0)
        z = l1 * t[None, :, 0, 2] + l2 * t[None, :, 1, 2] + l3 * t[None, :, 2, 2]
        res[i0:i0 + step] = (np.sum(hit & (z > q[:, None, 2]), axis=1) % 2) == 1
    return res

def overlap(A, B, h=0.4):
    """volume (mm3) common to both meshes, on a grid of pitch h nudged off round coordinates"""
    lo = np.maximum(A.reshape(-1, 3).min(0), B.reshape(-1, 3).min(0))
    hi = np.minimum(A.reshape(-1, 3).max(0), B.reshape(-1, 3).max(0))
    if np.any(hi - lo <= 0): return 0.0, None
    ax = [np.arange(lo[i] + 0.137 * h, hi[i], h) for i in range(3)]
    g = np.stack(np.meshgrid(*ax, indexing='ij'), -1).reshape(-1, 3)
    ia = inside(A, g)
    both = np.zeros(len(g), bool); both[ia] = inside(B, g[ia])
    return both.sum() * h ** 3, (g[both].min(0), g[both].max(0)) if both.any() else None

def section(tris, axis, value):
    d = tris[:, :, axis] - value
    keep = [a for a in range(3) if a != axis]
    segs = []
    cross = (d.min(1) < 0) & (d.max(1) > 0)
    for t, dd in zip(tris[cross], d[cross]):
        pts = []
        for i in range(3):
            j = (i + 1) % 3
            if (dd[i] < 0) != (dd[j] < 0):
                f = dd[i] / (dd[i] - dd[j])
                pts.append(t[i] + f * (t[j] - t[i]))
        if len(pts) == 2: segs.append([pts[0][keep], pts[1][keep]])
    return segs

src, out = sys.argv[1], sys.argv[2]
parts = {'lb_mock_corner': (130, 130, 130), 'lb_corner_block_A': (30, 80, 200), 'lb_bracket_A': (200, 90, 20), 'lb_foot_A': (20, 150, 60), 'lb_handle_A': (150, 30, 150)}
mesh = {k: load(os.path.join(src, k + '.STL')) for k in parts if os.path.exists(os.path.join(src, k + '.STL'))}
for k, m in mesh.items():
    v = m.reshape(-1, 3)
    print('%-18s %6d triangles  x %.1f..%.1f  y %.1f..%.1f  z %.1f..%.1f' % (k, len(m), v[:, 0].min(), v[:, 0].max(), v[:, 1].min(), v[:, 1].max(), v[:, 2].min(), v[:, 2].max()))

print('\noverlap volumes (mm3; 0 = clear):')
names = list(mesh)
for i in range(len(names)):
    for j in range(i + 1, len(names)):
        if {names[i], names[j]} == {'lb_bracket_A', 'lb_foot_A'}: continue   # alternatives for the same place
        if {names[i], names[j]} == {'lb_foot_A', 'lb_handle_A'}: continue      # the handle goes on a top corner, with the plain bracket
        vol, box = overlap(mesh[names[i]], mesh[names[j]])
        print('  %-18s vs %-18s %8.1f' % (names[i], names[j], vol) + ('   in x %.1f..%.1f y %.1f..%.1f z %.1f..%.1f' % (box[0][0], box[1][0], box[0][1], box[1][1], box[0][2], box[1][2]) if box else ''))

# sections: (axis, value, title, horizontal range, vertical range) in the two remaining axes, in xyz order
cuts = [(1, -20.65, 'y = -20.65: through the M6 insert (x right, z up)', (-60, 15), (-58, 36)),
        (1, -12.75, 'y = -12.75: through a bracket screw and the head relief', (-60, 15), (-58, 36)),
        (1, -55.0, 'y = -55: side tongue inside the channel', (-60, 15), (-58, 36)),
        (1, 5.0, 'y = +5: past the housing end, through the sole', (-60, 15), (-130, 60)),
        (2, 20.3, 'z = 20.3: plan through body, tongues, pilots (x right, y up)', (-60, 15), (-80, 12)),
        (2, 27.0, 'z = 27: plan through the diffuser', (-60, 15), (-80, 12)),
        (0, -5.05, 'x = -5.05: along the side arm (y right, z up)', (-80, 12), (-58, 36)),
        (0, 6.0, 'x = +6: through the leg, gusset and sole (y right, z up)', (-40, 14), (-130, 60)),
        (0, -10.0, 'x = -10: land A on the housing end; relief over the lap and corner screw (y right, z up)', (-40, 14), (-60, 36)),
        (0, -53.0, 'x = -53: land B on the tab', (-40, 14), (-60, 36)),
        (1, 1.0, 'y = +1: plan just past the housing end: lands, lap, corner screw (x right, z up)', (-70, 15), (-58, 36)),
        (2, -8.0, 'z = -8: plan through the lap on the side and the end (x right, y up)', (-60, 15), (-40, 14))]
sc = 7; pad = 24
tiles = []
for axis, val, title, xl, yl in cuts:
    w, h = int((xl[1] - xl[0]) * sc), int((yl[1] - yl[0]) * sc)
    im = Image.new('RGB', (w + 2 * pad, h + 2 * pad), 'white'); dr = ImageDraw.Draw(im)
    for gx in range(int(np.ceil(xl[0] / 10) * 10), int(xl[1]) + 1, 10):
        X = pad + (gx - xl[0]) * sc; dr.line([(X, pad), (X, pad + h)], fill=(230, 230, 230)); dr.text((X + 2, pad + h + 2), str(gx), fill=(120, 120, 120))
    for gy in range(int(np.ceil(yl[0] / 10) * 10), int(yl[1]) + 1, 10):
        Y = pad + (yl[1] - gy) * sc; dr.line([(pad, Y), (pad + w, Y)], fill=(230, 230, 230)); dr.text((2, Y - 5), str(gy), fill=(120, 120, 120))
    for k, col in parts.items():
        if k not in mesh: continue
        for a, b in section(mesh[k], axis, val):
            dr.line([(pad + (a[0] - xl[0]) * sc, pad + (yl[1] - a[1]) * sc), (pad + (b[0] - xl[0]) * sc, pad + (yl[1] - b[1]) * sc)], fill=col, width=2)
    dr.text((pad, 4), title, fill='black')
    tiles.append(im)
sheet = Image.new('RGB', (sum(t.width for t in tiles), max(t.height for t in tiles)), 'white')
x = 0
for t in tiles: sheet.paste(t, (x, 0)); x += t.width
sheet.save(out)
print('\nsections ->', out, ' (grey mock, blue block, orange bracket, green foot)')

# ---- saddle handle against the stand-in for the driver channel
# (its own frame: x along the channel, y across it, z up from the top of the lid)
sp = {'lb_mock_channel': (130, 130, 130), 'lb_saddle_handle': (150, 30, 150)}
sm = {k: load(os.path.join(src, k + '.STL')) for k in sp if os.path.exists(os.path.join(src, k + '.STL'))}
if len(sm) == 2:
    vol, box = overlap(sm['lb_saddle_handle'], sm['lb_mock_channel'], h=0.8)   # coarser grid: the pair is large and 0.4 takes half an hour
    print('\n  %-18s vs %-18s %8.1f' % ('lb_saddle_handle', 'lb_mock_channel', vol) + ('   in x %.1f..%.1f y %.1f..%.1f z %.1f..%.1f' % (box[0][0], box[1][0], box[0][1], box[1][1], box[0][2], box[1][2]) if box else ''))
    cuts = [(0, 29.6, 'x = 29.6: across the channel through a pair of inserts (y right, z up)', (-60, 60), (-42, 95)),
            (0, 0.0, 'x = 0: across the channel at the middle of the grip', (-60, 60), (-42, 95)),
            (0, 69.65, 'x = 69.65: through a bail leg', (-60, 60), (-42, 95)),
            (1, 0.0, 'y = 0: along the channel on the centre line (x right, z up)', (-100, 100), (-42, 95)),
            (1, 45.4, 'y = 45.4: along the channel through one leg', (-100, 100), (-42, 95))]
    tiles = []
    for axis, val, title, xl, yl in cuts:
        w, h = int((xl[1] - xl[0]) * sc), int((yl[1] - yl[0]) * sc)
        im = Image.new('RGB', (w + 2 * pad, h + 2 * pad), 'white'); dr = ImageDraw.Draw(im)
        for gx in range(int(np.ceil(xl[0] / 10) * 10), int(xl[1]) + 1, 10):
            X = pad + (gx - xl[0]) * sc; dr.line([(X, pad), (X, pad + h)], fill=(230, 230, 230)); dr.text((X + 2, pad + h + 2), str(gx), fill=(120, 120, 120))
        for gy in range(int(np.ceil(yl[0] / 10) * 10), int(yl[1]) + 1, 10):
            Y = pad + (yl[1] - gy) * sc; dr.line([(pad, Y), (pad + w, Y)], fill=(230, 230, 230)); dr.text((2, Y - 5), str(gy), fill=(120, 120, 120))
        for k, col in sp.items():
            for a, b in section(sm[k], axis, val):
                dr.line([(pad + (a[0] - xl[0]) * sc, pad + (yl[1] - a[1]) * sc), (pad + (b[0] - xl[0]) * sc, pad + (yl[1] - b[1]) * sc)], fill=col, width=2)
        dr.text((pad, 4), title, fill='black')
        tiles.append(im)
    rows = [tiles[:3], tiles[3:]]
    sheet = Image.new('RGB', (max(sum(t.width for t in r) for r in rows), sum(max(t.height for t in r) for r in rows)), 'white')
    y = 0
    for r in rows:
        x = 0
        for t in r: sheet.paste(t, (x, y)); x += t.width
        y += max(t.height for t in r)
    so = os.path.splitext(out)[0] + '_saddle.png'
    sheet.save(so)
    print('sections ->', so, ' (grey channel with washers, purple saddle handle)')
