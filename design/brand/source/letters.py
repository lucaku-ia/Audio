"""The lucaku. wordmark, drawn letter by letter.

Units: baseline y=0, y grows downward (SVG), x-height 500, ascender 735.
Shared DNA with the mark:
  * nib cut   - every stem top is sheared 18 units, rising left to right, like a
                broad pen held at a shallow angle. It is the signature detail.
  * the tail  - the l (and both bowls of u) turn out to the right on the baseline.
  * the point - the full stop that ends the name. It is the answer, and in motion
                it is the voice (see BRAND.md).
Horizontals and curves (WB) are drawn lighter than stems (WS), which is what keeps
the round letters from looking heavier than the straight ones.
"""
import geometry as lk, skia, math
WS = 92   # stem
WB = 84   # bowls / curves (horizontals optically lighter)
XH = 500; ASC = 735; OS = 9  # x-height, ascender, overshoot

def cut_top(shape, x0, x1, yl, yr):
    # slanted nib cut across a stem top: remove everything above line (x0,yl)-(x1,yr)
    ang = math.degrees(math.atan2(yr - yl, x1 - x0))
    return lk.diff(shape, lk.rotated_cut(x0, yl, ang, side=-1))

def clip_base(shape, y=0):
    return lk.diff(shape, lk.rect(-5000, y, 10000, 5000))

def stem(xc, ytop, ybot=0, w=WS):
    return lk.rect(xc - w/2, ytop - 60, w, ybot - ytop + 60)

def nib(shape, xc, ytop, w=WS, rise=18):
    return cut_top(shape, xc - w/2, xc + w/2, ytop + rise/2, ytop - rise/2)

def g_l():
    s = lk.stroke(lk.path([('M',46,-ASC-80),('L',46,-175),('C',46,-78,98,-WB/2+OS,182,-WB/2+OS)]), WS)
    s = nib(s, 46, -ASC)
    return s, 214

def g_u():
    x2 = 352
    bowl = lk.stroke(lk.path([('M',46,-XH-80),('L',46,-200),('C',46,-85,105,-WB/2+OS,192,-WB/2+OS),('C',262,-WB/2+OS,x2-8,-78,x2,-175)]), WS)
    right = stem(x2, -XH)
    s = lk.union(nib(bowl, 46, -XH), nib(right, x2, -XH))
    s = clip_base(s, OS)
    s = lk.diff(s, lk.rect(x2 - WS/2 - 1, -5, WS + 2, 100))  # square the right foot
    s = lk.union(s, lk.rect(x2 - WS/2, -40, WS, 40))
    return s, x2 + WS/2 + 58

def g_c():
    cx, cy, rx, ry = 214, -XH/2, 172, XH/2 + OS - WB/2
    arc = lk.P(); arc.addArc(skia.Rect.MakeLTRB(cx-rx, cy-ry, cx+rx, cy+ry), -48, -264)
    s = lk.stroke(arc, WB)
    s = lk.diff(s, lk.rect(cx + 138, -1000, 1000, 2000))   # vertical terminal cuts
    return s, cx + 138 + 34

def g_a():
    xs = 318
    ty = -XH - OS + WB/2
    shoulder = lk.stroke(lk.path([('M',xs,-372),('C',xs,-446,262,ty,184,ty),('C',124,ty,80,-452,58,-414)]), WB)
    bowl = lk.stroke(lk.path([('M',xs,-262),('C',xs-40,-280,240,-286,192,-286),('C',98,-286,48,-234,48,-150),('C',48,-72,104,-WB/2+OS+2,178,-WB/2+OS+2),('C',248,-WB/2+OS+2,298,-66,xs,-130),('L',xs,-262),('Z',)]), 74)
    taper = lk.poly((xs-WS/2,-300),(xs+WS/2,-300),(xs+WB/2,-374),(xs-WB/2,-374))
    s = lk.union(shoulder, taper, lk.rect(xs - WS/2, -300, WS, 300), bowl)
    s = clip_base(s, OS)
    s = lk.diff(s, lk.rect(xs - WS/2 - 1, -5, WS + 2, 100))
    s = lk.union(s, lk.rect(xs - WS/2, -40, WS, 40))
    return s, xs + WS/2 + 66

def g_k():
    st = nib(clip_base(stem(46, -ASC)), 46, -ASC)
    arm = lk.stroke(lk.path([('M',46,-150),('L',340,-XH-60)]), 86)
    arm = lk.diff(arm, lk.rect(-1000, -XH - 2000, 3000, 2000))
    leg = lk.stroke(lk.path([('M',175,-295),('L',360,40)]), 90)
    leg = clip_base(leg)
    s = lk.translate(lk.union(st, arm, leg), 30, 0)
    return s, 30 + 405 + 50

def wordmark_parts(tracking=0):
    """(letters, point) as separate shapes, so the point can take the accent."""
    x = 0; parts = []
    for g in (g_l, g_u, g_c, g_a, g_k, g_u):
        s, adv = g()
        parts.append(lk.translate(s, x, 0)); x += adv + tracking
    r = 54
    return lk.union(*parts), lk.circle(x + 4 + r, -r + OS - 2, r)


def wordmark(dot=True, tracking=0):
    x = 0; parts = []
    for g in (g_l, g_u, g_c, g_a, g_k, g_u):
        s, adv = g()
        parts.append(lk.translate(s, x, 0)); x += adv + tracking
    out = lk.union(*parts)
    if dot:
        r = 54
        out = lk.union(out, lk.circle(x + 4 + r, -r + OS - 2, r))
    return out

