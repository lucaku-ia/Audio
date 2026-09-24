"""Regenerates every file in design/brand/logo, app-icon and explorations.

    pip install skia-python      # Linux also needs libegl1 + libgl1
    python3 design/brand/source/build.py

Everything is derived from letters.py and mark.py; edit those, never the SVGs.
"""
import os
import geometry as lk
import letters
import mark as mk
import explorations
import skia

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

INK, ACCENT, ACCENT_DARK, WHITE, TEXT_DARK = '#1C1C1E', '#1E647E', '#74B9D1', '#FFFFFF', '#F2F2F2'
# Icon field: the approved accent, lit from the top. Both stops sit within the
# accent's own hue (#1E647E is their midpoint), so it reads as one colour.
FIELD_TOP, FIELD_BOTTOM = '#23708C', '#1A5870'


def write(rel, text):
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(text)
    print('wrote', rel)


def svg_for(shape, fill, title, pad=0.0):
    l, t, r, b = lk.bounds(shape)
    p = pad
    vb = f'{lk.fmt(l - p)} {lk.fmt(t - p)} {lk.fmt(r - l + 2 * p)} {lk.fmt(b - t + 2 * p)}'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" role="img" aria-label="{title}">'
            f'<title>{title}</title><path fill="{fill}" d="{lk.d(shape)}"/></svg>\n')


def icon_parts(size=1024):
    glyph = mk.fit(mk.mark(), height=560 * size / 1000, cx=size / 2, cy=505 * size / 1000)
    l, t, r, b = lk.bounds(glyph)
    split = lk.rect(r - 0.2 * size, t - 10, size, size)
    dot = lk.inter(glyph, split)
    return lk.diff(glyph, dot), dot


def icon_svg(variant, size=1024):
    stem, dot = icon_parts(size)
    if variant == 'light':
        bg = (f'<defs><linearGradient id="f" x1="0" y1="0" x2="0" y2="1">'
              f'<stop offset="0" stop-color="{FIELD_TOP}"/><stop offset="1" stop-color="{FIELD_BOTTOM}"/></linearGradient>'
              f'<radialGradient id="g" cx="0.3" cy="0.12" r="0.9"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.07"/>'
              f'<stop offset="0.6" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient></defs>'
              f'<rect width="{size}" height="{size}" fill="url(#f)"/><rect width="{size}" height="{size}" fill="url(#g)"/>')
        fl, fd = WHITE, WHITE
    elif variant == 'dark':      # iOS supplies the dark field; the glyph carries the colour
        bg, fl, fd = '', TEXT_DARK, ACCENT_DARK
    else:                        # tinted: iOS recolours by luminance, so plain white
        bg, fl, fd = '', WHITE, WHITE
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}" '
            f'role="img" aria-label="Lucaku app icon"><title>Lucaku app icon</title>{bg}'
            f'<path fill="{fl}" d="{lk.d(stem)}"/><path fill="{fd}" d="{lk.d(dot)}"/></svg>\n')


def hex_color(h, a=1.0):
    h = h.lstrip('#')
    return skia.Color4f(int(h[0:2], 16) / 255, int(h[2:4], 16) / 255, int(h[4:6], 16) / 255, a)


def icon_png(variant, rel, size=1024):
    stem, dot = icon_parts(size)
    surface = skia.Surface(size, size)
    c = surface.getCanvas()
    c.clear(skia.Color4f(0, 0, 0, 0))
    if variant == 'light':
        field = skia.Paint(Shader=skia.GradientShader.MakeLinear(
            [skia.Point(0, 0), skia.Point(0, size)], [hex_color(FIELD_TOP).toColor(), hex_color(FIELD_BOTTOM).toColor()]))
        c.drawRect(skia.Rect.MakeWH(size, size), field)
        glow = skia.Paint(Shader=skia.GradientShader.MakeRadial(
            skia.Point(0.3 * size, 0.12 * size), 0.9 * size,
            [skia.Color4f(1, 1, 1, 0.07).toColor(), skia.Color4f(1, 1, 1, 0).toColor()], [0.0, 0.6]))
        c.drawRect(skia.Rect.MakeWH(size, size), glow)
        fl, fd = WHITE, WHITE
    elif variant == 'dark':
        fl, fd = TEXT_DARK, ACCENT_DARK
    else:
        fl, fd = WHITE, WHITE
    c.drawPath(stem, skia.Paint(AntiAlias=True, Color4f=hex_color(fl)))
    c.drawPath(dot, skia.Paint(AntiAlias=True, Color4f=hex_color(fd)))
    img = surface.makeImageSnapshot()
    if variant == 'light':   # App Store icons must be opaque
        img = img.convert(alphaType=skia.kOpaque_AlphaType)
    path = os.path.join(ROOT, rel)
    img.save(path, skia.kPNG)
    print('wrote', rel)


def home_cells(dark):
    tones = (['#2C2C2E', '#3A3A3C', '#242426', '#303033', '#1F2224', '#343437'] if dark
             else ['#E9E9EE', '#D8DDE0', '#F3EFE9', '#CFD6D9', '#E3E1DC', '#DFE4E7'])
    names = ['Calendario', 'Fotos', 'Cámara', 'Mapas', 'Notas', 'Lucaku', 'Clima', 'Reloj',
             'Correo', 'Música', 'Ajustes', 'Wallet']
    out = []
    for i, n in enumerate(names):
        if n == 'Lucaku':
            ref = '#icon-dark' if dark else '#icon-light'
            out.append(f'<div class="app"><svg class="icon" width="60" height="60" aria-hidden="true"><use href="{ref}"/></svg><span>Lucaku</span></div>')
        else:
            out.append(f'<div class="app"><i style="background:{tones[i % 6]}"></i><span>{n}</span></div>')
    return '\n            '.join(out)


def showcase():
    letters_, point = letters.wordmark_parts()
    l, t, r, b = lk.bounds(lk.union(letters_, point))
    pad = 8
    m = mk.mark()
    ml, mt, mr, mb = lk.bounds(m)
    mdot = lk.inter(m, lk.rect(mr - 200, mt - 10, 400, 2000))
    mstem = lk.diff(m, mdot)
    istem, idot = icon_parts(1000)
    xh = letters.XH
    g_l, _ = letters.g_l()
    _, u_adv = letters.g_l()
    u_shape, _ = letters.g_u()
    ul, ut, ur, ub = lk.bounds(u_shape)
    vals = {
        'WM_VB': f'{lk.fmt(l - pad)} {lk.fmt(t - pad)} {lk.fmt(r - l + 2 * pad)} {lk.fmt(b - t + 2 * pad)}',
        'WM_LETTERS': lk.d(letters_), 'WM_DOT': lk.d(point),
        'MARK_VB': f'{lk.fmt(ml)} {lk.fmt(mt)} {lk.fmt(mr - ml)} {lk.fmt(mb - mt)}',
        'MARK_STEM': lk.d(mstem), 'MARK_DOT': lk.d(mdot),
        'ICON_STEM': lk.d(istem), 'ICON_DOT': lk.d(idot),
        'CS_VB': f'{lk.fmt(l - xh - 40)} {lk.fmt(t - xh - 40)} {lk.fmt(r - l + 2 * xh + 80)} {lk.fmt(b - t + 2 * xh + 80)}',
        'CS_X': lk.fmt(l - xh), 'CS_Y': lk.fmt(t - xh), 'CS_W': lk.fmt(r - l + 2 * xh), 'CS_H': lk.fmt(b - t + 2 * xh),
        'U_X': lk.fmt(u_adv + ul), 'U_W': lk.fmt(ur - ul),
        'WM_L_ONLY': lk.d(g_l),
        'HOME_LIGHT': home_cells(False), 'HOME_DARK': home_cells(True),
    }
    html = open(os.path.join(HERE, 'showcase.template.html')).read()
    for k, v in vals.items():
        html = html.replace('{{' + k + '}}', v)
    assert '{{' not in html, 'unfilled placeholder'
    write('brand_showcase.html', html)


def main():
    wm = letters.wordmark()
    m = mk.mark()
    colours = {'accent': ACCENT, 'ink': INK, 'white': WHITE, 'accent-dark': ACCENT_DARK}
    for name, fill in colours.items():
        write(f'logo/lucaku-wordmark-{name}.svg', svg_for(wm, fill, 'lucaku'))
        write(f'logo/lucaku-mark-{name}.svg', svg_for(m, fill, 'lucaku'))
    for variant in ('light', 'dark', 'tinted'):
        suffix = '' if variant == 'light' else f'-{variant}'
        write(f'app-icon/lucaku-app-icon{suffix}.svg', icon_svg(variant))
        icon_png(variant, f'app-icon/lucaku-app-icon{suffix}-1024.png')
    for name, fn in explorations.CONCEPTS:
        shape = fn()
        write(f'explorations/{name}.svg',
              f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000"><rect width="1000" height="1000" rx="224" fill="{ACCENT}"/>'
              f'<path fill="{WHITE}" d="{lk.d(shape)}"/></svg>\n')
    showcase()


if __name__ == '__main__':
    main()
