"""The compact mark: the wordmark's first and last characters, l and the point.

Same construction as letters.g_l, drawn heavier (stem 136 against a 600 height)
so the tail and the point still separate at 29px on a home screen.
"""
import geometry as lk, math
# The mark is the wordmark's first and last characters: the tailed l and the point.
# Drawn heavier than the wordmark (stem/height 0.19 vs 0.125) so it survives 29px.
def mark(W=136, H=600, dot_ratio=1.28, gap=None):
    OS = W * 0.1
    tailx = W * 2.05                      # tail terminal x (from stem left edge)
    xc = W / 2
    s = lk.stroke(lk.path([('M', xc, -H - 100), ('L', xc, -W * 2.05),
                           ('C', xc, -W * 0.78, xc + W * 0.62, -W / 2 + OS, tailx, -W / 2 + OS)]), W)
    rise = W * 0.2
    ang = math.degrees(math.atan2(-rise, W))
    s = lk.diff(s, lk.rotated_cut(0, -H + rise / 2, ang, side=-1))
    r = W * dot_ratio / 2
    gap = W * 0.42 if gap is None else gap
    s = lk.union(s, lk.circle(tailx + gap + r, -r + OS, r))
    return s

def fit(p, box=1000, height=560, cx=500, cy=500, optical_dx=0.0):
    l, t, r, b = lk.bounds(p)
    k = height / (b - t)
    q = lk.translate(p, 0, 0, k)
    l, t, r, b = lk.bounds(q)
    return lk.translate(q, cx - (l + r) / 2 + optical_dx, cy - (t + b) / 2)

