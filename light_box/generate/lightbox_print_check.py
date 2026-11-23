"""Print check on the STL meshes: overhangs in the print orientation, and that hand B is the mirror of hand A.

    python lightbox_print_check.py <dir with lb_*.STL>

For each part: the area of surface that faces the bed at more than 45 deg from vertical and is not on the
bed, grouped by height above the bed. A group that is a few mm wide is a ledge or a short bridge; anything
large wants support or a design change. Horizontal holes show up as small groups.
"""
import sys, os, struct
import numpy as np

def load(path):
    data = open(path, 'rb').read()
    n = struct.unpack_from('<I', data, 80)[0]
    dt = np.dtype([('n', '<f4', 3), ('v', '<f4', (3, 3)), ('a', '<u2')])
    return np.frombuffer(data, dtype=dt, count=n, offset=84)['v'].astype(float)

# part -> (build axis, +1 if the print grows toward + on that axis)
ORIENT = {'lb_corner_block_A': (2, +1), 'lb_bracket_A': (1, +1), 'lb_foot_A': (1, -1), 'lb_spacer': (2, +1)}

def overhang(t, axis, sign):
    nrm = np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0]); area = np.linalg.norm(nrm, axis=1) / 2
    ok = area > 1e-9; t, nrm, area = t[ok], nrm[ok], area[ok]; nrm = nrm / (2 * area[:, None])
    h = sign * t[:, :, axis]; bed = h.min(); hc = h.mean(1) - bed
    down = -sign * nrm[:, axis]
    m = (down > 0.7072) & (h.min(1) - bed > 0.3)
    others = [i for i in range(3) if i != axis]
    out = []
    if m.any():
        key = np.round(hc[m] * 2) / 2
        for k in np.unique(key):
            sel = np.where(m)[0][key == k]
            v = t[sel].reshape(-1, 3)
            ext = [v[:, o].max() - v[:, o].min() for o in others]
            out.append((k, area[sel].sum(), down[sel].min() > 0.999, ext, v.mean(0)))
    return out, hc.max()

def inside(tris, pts):
    a, b, c = tris[:, 0, :2], tris[:, 1, :2], tris[:, 2, :2]
    den = (b[:, 1] - c[:, 1]) * (a[:, 0] - c[:, 0]) + (c[:, 0] - b[:, 0]) * (a[:, 1] - c[:, 1])
    ok = np.abs(den) > 1e-12
    a, b, c, den, t = a[ok], b[ok], c[ok], den[ok], tris[ok]
    res = np.zeros(len(pts), bool)
    step = max(1, 3000000 // max(1, len(t)))
    for i0 in range(0, len(pts), step):
        q = pts[i0:i0 + step]
        l1 = ((b[:, 1] - c[:, 1])[None] * (q[:, None, 0] - c[None, :, 0]) + (c[:, 0] - b[:, 0])[None] * (q[:, None, 1] - c[None, :, 1])) / den[None]
        l2 = ((c[:, 1] - a[:, 1])[None] * (q[:, None, 0] - c[None, :, 0]) + (a[:, 0] - c[:, 0])[None] * (q[:, None, 1] - c[None, :, 1])) / den[None]
        l3 = 1 - l1 - l2
        hit = (l1 > 0) & (l2 > 0) & (l3 > 0)
        z = l1 * t[None, :, 0, 2] + l2 * t[None, :, 1, 2] + l3 * t[None, :, 2, 2]
        res[i0:i0 + step] = (np.sum(hit & (z > q[:, None, 2]), axis=1) % 2) == 1
    return res

src = sys.argv[1]
print('OVERHANGS (facing the bed at more than 45 deg from vertical, not on the bed)')
for name, (axis, sign) in ORIENT.items():
    f = os.path.join(src, name + '.STL')
    if not os.path.exists(f): continue
    groups, height = overhang(load(f), axis, sign)
    tot = sum(g[1] for g in groups)
    print('%-18s print height %.1f, overhang area %.0f mm2' % (name, height, tot))
    for k, ar, flat, ext, c in groups:
        if ar < 3: continue
        print('    at %5.1f above the bed: %6.1f mm2 %s, spread %.0f x %.0f, near x %.0f y %.0f z %.0f' % (k, ar, 'flat' if flat else 'sloped', ext[0], ext[1], c[0], c[1], c[2]))

print('\nHAND B AGAINST THE MIRROR OF HAND A (volume in one but not the other, 0.5 mm grid)')
for base in ('lb_corner_block', 'lb_bracket', 'lb_foot'):
    fa, fb = os.path.join(src, base + '_A.STL'), os.path.join(src, base + '_B.STL')
    if not (os.path.exists(fa) and os.path.exists(fb)): continue
    A, B = load(fa), load(fb).copy(); B[:, :, 0] *= -1
    lo = np.minimum(A.reshape(-1, 3).min(0), B.reshape(-1, 3).min(0)); hi = np.maximum(A.reshape(-1, 3).max(0), B.reshape(-1, 3).max(0))
    h = 0.5; ax = [np.arange(lo[i] + 0.137 * h, hi[i], h) for i in range(3)]
    g = np.stack(np.meshgrid(*ax, indexing='ij'), -1).reshape(-1, 3)
    ia, ib = inside(A, g), inside(B, g)
    print('  %-16s A %.1f cm3, B mirrored %.1f cm3, difference %.2f cm3' % (base, ia.sum() * h ** 3 / 1000, ib.sum() * h ** 3 / 1000, (ia ^ ib).sum() * h ** 3 / 1000))
