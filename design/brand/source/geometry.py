"""Vector geometry helpers: stroke skeletons outlined to filled contours with Skia,
boolean path ops, and a compact SVG path serializer. All logo geometry is built
from these, so every exported SVG is plain filled outlines (no strokes, no fonts)."""
import skia, math

def P(): return skia.Path()

def pts(*a):
    return [skia.Point(float(x), float(y)) for x, y in a]

def path(cmds):
    """cmds: list of tuples ('M',x,y) ('L',x,y) ('C',x1,y1,x2,y2,x,y) ('Q',x1,y1,x,y) ('Z',)"""
    p = P()
    for c in cmds:
        k = c[0]
        if k == 'M': p.moveTo(*c[1:])
        elif k == 'L': p.lineTo(*c[1:])
        elif k == 'C': p.cubicTo(*c[1:])
        elif k == 'Q': p.quadTo(*c[1:])
        elif k == 'Z': p.close()
    return p

CAPS = {'butt': skia.Paint.kButt_Cap, 'round': skia.Paint.kRound_Cap, 'square': skia.Paint.kSquare_Cap}
JOINS = {'miter': skia.Paint.kMiter_Join, 'round': skia.Paint.kRound_Join, 'bevel': skia.Paint.kBevel_Join}

def stroke(p, w, cap='butt', join='round'):
    paint = skia.Paint(Style=skia.Paint.kStroke_Style, StrokeWidth=w, StrokeCap=CAPS[cap], StrokeJoin=JOINS[join], AntiAlias=True)
    dst = P()
    paint.getFillPath(p, dst, None, 16.0)
    return simplify(dst)

def simplify(p):
    e = P(); e.setFillType(skia.PathFillType.kWinding)
    return skia.Op(p, e, skia.PathOp.kUnion_PathOp) or p

def union(*ps):
    out = ps[0]
    for q in ps[1:]:
        out = skia.Op(out, q, skia.PathOp.kUnion_PathOp)
    return out

def diff(a, b): return skia.Op(a, b, skia.PathOp.kDifference_PathOp)
def inter(a, b): return skia.Op(a, b, skia.PathOp.kIntersect_PathOp)

def circle(cx, cy, r):
    p = P(); p.addCircle(cx, cy, r); return p

def rect(x, y, w, h):
    p = P(); p.addRect(skia.Rect.MakeXYWH(x, y, w, h)); return p

def poly(*a):
    p = P(); p.addPoly(pts(*a), True); return p

def translate(p, dx, dy, s=1.0):
    m = skia.Matrix(); m.setScaleTranslate(s, s, dx, dy)
    q = P(); p.transform(m, q); return q

def rotated_cut(cx, cy, angle_deg, side=1, size=2000):
    """half-plane through (cx,cy) at angle; side selects which half. returns big polygon to subtract"""
    a = math.radians(angle_deg)
    dx, dy = math.cos(a), math.sin(a)
    nx, ny = -dy * side, dx * side
    p1 = (cx - dx*size, cy - dy*size); p2 = (cx + dx*size, cy + dy*size)
    p3 = (p2[0] + nx*size, p2[1] + ny*size); p4 = (p1[0] + nx*size, p1[1] + ny*size)
    return poly(p1, p2, p3, p4)

def fmt(v):
    s = f"{v:.1f}"
    s = s.rstrip('0').rstrip('.') if '.' in s else s
    return '0' if s in ('-0', '') else s

def d(p):
    out = []
    it = skia.Path.Iter(p, False)
    V = skia.Path.Verb
    while True:
        verb, ps = it.next()
        if verb == V.kDone_Verb: break
        if verb == V.kMove_Verb: out.append(f"M{fmt(ps[0].x())} {fmt(ps[0].y())}")
        elif verb == V.kLine_Verb: out.append(f"L{fmt(ps[1].x())} {fmt(ps[1].y())}")
        elif verb == V.kQuad_Verb: out.append(f"Q{fmt(ps[1].x())} {fmt(ps[1].y())} {fmt(ps[2].x())} {fmt(ps[2].y())}")
        elif verb == V.kConic_Verb:
            # convert conic to quads
            w = it.conicWeight()
            quads = skia.Path.ConvertConicToQuads(ps[0], ps[1], ps[2], w, 2)
            for i in range(1, len(quads), 2):
                out.append(f"Q{fmt(quads[i].x())} {fmt(quads[i].y())} {fmt(quads[i+1].x())} {fmt(quads[i+1].y())}")
        elif verb == V.kCubic_Verb: out.append(f"C{fmt(ps[1].x())} {fmt(ps[1].y())} {fmt(ps[2].x())} {fmt(ps[2].y())} {fmt(ps[3].x())} {fmt(ps[3].y())}")
        elif verb == V.kClose_Verb: out.append("Z")
    return ''.join(out)

def bounds(p):
    r = p.computeTightBounds(); return (r.left(), r.top(), r.right(), r.bottom())
