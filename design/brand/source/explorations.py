"""The eight mark concepts explored before settling on the point.

Kept so the reasoning is inspectable, not as alternatives to use.
See ../explorations/README.md for why each was rejected.
"""
import geometry as lk
import skia


def a_pregunta():
    """The Spanish opening question mark, drawn as an L."""
    body = lk.path([('M', 500, 340), ('L', 500, 440), ('C', 500, 520, 360, 560, 360, 680),
                    ('C', 360, 795, 455, 852, 565, 852), ('C', 645, 852, 705, 818, 748, 760)])
    return lk.union(lk.stroke(body, 118), lk.circle(500, 205, 80))


def b_oido():
    """An L whose foot curls into the helix of an ear."""
    return lk.stroke(lk.path([('M', 380, 140), ('L', 380, 600), ('C', 380, 760, 470, 852, 600, 852),
                              ('C', 725, 852, 800, 765, 800, 650), ('C', 800, 540, 725, 470, 630, 470),
                              ('C', 565, 470, 525, 512, 525, 568)]), 112)


def c_voz():
    """Loudness envelope of the spoken name: lu (soft onset), ca, ku (plosive bursts)."""
    def lobe(x0, x1, h, attack, axis=500):
        xp = x0 + (x1 - x0) * attack
        k = 0.55 if attack < 0.1 else 0.2
        return lk.path([('M', x0, axis), ('C', x0, axis - h * k, xp - (xp - x0) * 0.6, axis - h, xp, axis - h),
                        ('C', xp + (x1 - xp) * 0.45, axis - h, x1 - (x1 - xp) * 0.25, axis - h * 0.08, x1, axis),
                        ('C', x1 - (x1 - xp) * 0.25, axis + h * 0.08, xp + (x1 - xp) * 0.45, axis + h, xp, axis + h),
                        ('C', xp - (xp - x0) * 0.6, axis + h, x0, axis + h * k, x0, axis), ('Z',)])
    return lk.union(lobe(110, 330, 105, 0.45), lobe(385, 705, 205, 0.07), lobe(755, 905, 125, 0.06))


def d_respuesta():
    """An open listening form holding a single point."""
    ring = lk.P(); ring.addArc(skia.Rect.MakeLTRB(210, 230, 750, 770), 38, 284)
    return lk.union(lk.stroke(ring, 112), lk.circle(505, 500, 78))


def e1_l_punto():
    """A square L holding a point in its crook."""
    return lk.union(lk.stroke(lk.path([('M', 360, 170), ('L', 360, 790), ('L', 720, 790)]), 130, 'butt', 'miter'),
                    lk.circle(560, 590, 72))


def e2_l_cuenco():
    """An L whose foot cups upward, like a hand to the ear, holding the point."""
    return lk.union(lk.stroke(lk.path([('M', 350, 160), ('L', 350, 610), ('C', 350, 760, 440, 830, 560, 830),
                                       ('C', 690, 830, 760, 745, 775, 610)]), 130), lk.circle(565, 585, 70))


def e3_l_punto_final():
    """A tailed l followed by a full stop. The direction that was developed."""
    return lk.union(lk.stroke(lk.path([('M', 400, 150), ('L', 400, 650), ('C', 400, 770, 470, 830, 560, 830)]), 130),
                    lk.circle(690, 775, 75))


def e4_l_frase():
    """An L whose foot is one soft spoken undulation."""
    return lk.stroke(lk.path([('M', 330, 160), ('L', 330, 700), ('C', 330, 790, 380, 820, 450, 790),
                              ('C', 520, 760, 560, 690, 640, 700), ('C', 720, 710, 740, 790, 800, 800)]), 130)


CONCEPTS = [
    ('a-pregunta', a_pregunta), ('b-oido', b_oido), ('c-voz', c_voz), ('d-respuesta', d_respuesta),
    ('e1-l-punto', e1_l_punto), ('e2-l-cuenco', e2_l_cuenco), ('e3-l-punto-final', e3_l_punto_final),
    ('e4-l-frase', e4_l_frase),
]
