#!/usr/bin/env python3
"""Writes Burrow's app icon and mark as SVG. Edit this script, not the SVG files.

    python3 scripts/generate_icon.py               # Resources/AppIcon.svg, docs/images/burrow-mark.svg
    python3 scripts/generate_icon.py --layers DIR  # also the tunnel and light layers on their own

Geometry: Apple's macOS icon grid (1024 canvas, 824 body at offset 100, continuous corner
radius 185.4). A frame of constant thickness stands on the ground line around the opening;
the tunnel's cross-sections are the opening scaled by K about the vanishing point (512, VY),
so the floor edges lie on lines through it. The glyph's bounding box is centred at (512, 512).
build_app.sh renders AppIcon.svg into AppIcon.icns with scripts/render_icon.swift.
"""
import argparse
import os

C = 1024; BODY = 824; M = (C - BODY) / 2; R = 185.4; CX = C / 2
W0, H0 = 528, 600                      # outer arch width and height
T0 = CX - H0 / 2; B0 = CX + H0 / 2       # glyph bbox centred at (512, 512)
RIM = 80                                 # frame thickness, equal on the crown and both pillars
P_HW, P_T = W0 / 2 - RIM, T0 + RIM       # opening: half-width and top; it stands on the same ground B0
VY = P_T + 0.6 * (B0 - P_T)              # vanishing point (512, VY)
K = 0.7; N = 3                           # opening, one more arch, then the light at the end

def f(v): return f"{v:.3f}".rstrip("0").rstrip(".")

def squircle(x, y, w, h, r):
    # Apple continuous-corner rounded rectangle, y down.
    a, b, c, d, e, g, k = 1.52866483, 1.08849323, 0.86840689, 0.66993427, 0.06549600, 0.36745363, 0.17923160
    X0, Y0, X1, Y1 = x, y, x + w, y + h
    return "".join([f"M{f(X0+a*r)} {f(Y0)}", f"L{f(X1-a*r)} {f(Y0)}",
        f"C{f(X1-b*r)} {f(Y0)} {f(X1-c*r)} {f(Y0)} {f(X1-d*r)} {f(Y0+e*r)}",
        f"C{f(X1-g*r)} {f(Y0+k*r)} {f(X1-k*r)} {f(Y0+g*r)} {f(X1-e*r)} {f(Y0+d*r)}",
        f"C{f(X1)} {f(Y0+c*r)} {f(X1)} {f(Y0+b*r)} {f(X1)} {f(Y0+a*r)}", f"L{f(X1)} {f(Y1-a*r)}",
        f"C{f(X1)} {f(Y1-b*r)} {f(X1)} {f(Y1-c*r)} {f(X1-e*r)} {f(Y1-d*r)}",
        f"C{f(X1-k*r)} {f(Y1-g*r)} {f(X1-g*r)} {f(Y1-k*r)} {f(X1-d*r)} {f(Y1-e*r)}",
        f"C{f(X1-c*r)} {f(Y1)} {f(X1-b*r)} {f(Y1)} {f(X1-a*r)} {f(Y1)}", f"L{f(X0+a*r)} {f(Y1)}",
        f"C{f(X0+b*r)} {f(Y1)} {f(X0+c*r)} {f(Y1)} {f(X0+d*r)} {f(Y1-e*r)}",
        f"C{f(X0+g*r)} {f(Y1-k*r)} {f(X0+k*r)} {f(Y1-g*r)} {f(X0+e*r)} {f(Y1-d*r)}",
        f"C{f(X0)} {f(Y1-c*r)} {f(X0)} {f(Y1-b*r)} {f(X0)} {f(Y1-a*r)}", f"L{f(X0)} {f(Y0+a*r)}",
        f"C{f(X0)} {f(Y0+b*r)} {f(X0)} {f(Y0+c*r)} {f(X0+e*r)} {f(Y0+d*r)}",
        f"C{f(X0+k*r)} {f(Y0+g*r)} {f(X0+g*r)} {f(Y0+k*r)} {f(X0+d*r)} {f(Y0+e*r)}",
        f"C{f(X0+c*r)} {f(Y0)} {f(X0+b*r)} {f(Y0)} {f(X0+a*r)} {f(Y0)}", "Z"])

def shape(hw, t, b, closed=True):
    # Arch with a semicircular top: half-width hw, top t, base b, centred on CX.
    yc = t + hw
    return f"M{f(CX-hw)} {f(b)}L{f(CX-hw)} {f(yc)}A{f(hw)} {f(hw)} 0 0 1 {f(CX+hw)} {f(yc)}L{f(CX+hw)} {f(b)}" + ("Z" if closed else "")

FRAME = shape(W0 / 2, T0, B0)

def box(s):
    # Tunnel cross-section at depth step s: the opening scaled by s about V.
    a = P_HW * s
    return CX - a, VY + (P_T - VY) * s, CX + a, VY + (B0 - VY) * s

def arch(s, closed=True):
    x0, t, x1, b = box(s)
    return shape((x1 - x0) / 2, t, b, closed)

def floor(i):
    # Floor between consecutive cross-sections; its side edges lie on lines through V.
    x0, _, x1, b0 = box(K ** i); u0, _, u1, b1 = box(K ** (i + 1))
    return f"M{f(x0)} {f(b0)}L{f(x1)} {f(b0)}L{f(u1)} {f(b1)}L{f(u0)} {f(b1)}Z", b1, b0

FRAME_FILL = ("#FFB45E", "#EE5F10")
# Tunnel walls (top, bottom): dark near the entrance, brightening toward the light.
RINGS = [("#7A2E10", "#4A1A0A"), ("#B4501C", "#7C3011")]
# Floor of each segment (far edge, near edge), lit by the light at the end.
FLOORS = [("#C25E22", "#6A2810"), ("#FFB257", "#D9732A")]

def lin(id, y0, y1, stops):
    s = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in stops)
    return f'<linearGradient id="{id}" x1="0" y1="{f(y0)}" x2="0" y2="{f(y1)}" gradientUnits="userSpaceOnUse">{s}</linearGradient>'

def rad(id, cx, cy, r, stops):
    s = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in stops)
    return f'<radialGradient id="{id}" cx="{f(cx)}" cy="{f(cy)}" r="{f(r)}" gradientUnits="userSpaceOnUse">{s}</radialGradient>'

def blur(id, sd): return f'<filter id="{id}" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="{sd}"/></filter>'

def svg(layer="full"):
    sq = squircle(M, M, BODY, BODY, R)
    _, lt, _, lb = box(K ** (N - 1))
    d = ["<defs>",
         lin("bg", M, M + BODY, [(0, "#4A3590", 1), (1, "#170F36", 1)]),
         rad("dome", CX, M + 120, BODY * 0.85, [(0, "#FFFFFF", 0.14), (0.6, "#FFFFFF", 0.03), (1, "#FFFFFF", 0)]),
         rad("glow", CX, VY, BODY * 0.55, [(0, "#FF8A1F", 0.18), (1, "#FF8A1F", 0)]),
         lin("edge", M, M + BODY, [(0, "#FFFFFF", 0.38), (0.5, "#FFFFFF", 0.08), (1, "#FFFFFF", 0.05)]),
         lin("sheen", T0, B0, [(0, "#FFFFFF", 0.55), (0.45, "#FFFFFF", 0.0), (1, "#FFFFFF", 0)]),
         lin("frame", T0, B0, [(0, FRAME_FILL[0], 1), (1, FRAME_FILL[1], 1)]),
         lin("spec", T0, B0, [(0, "#FFFFFF", 0.95), (0.35, "#FFFFFF", 0.35), (1, "#FFFFFF", 0)]),
         lin("refr", P_T, B0, [(0, "#FFE2B0", 0.0), (0.4, "#FFE2B0", 0.45), (1, "#FFE2B0", 0.15)]),
         blur("b2", 1.6),
         lin("foot", B0 - 90, B0, [(0, "#2A0C02", 0), (1, "#2A0C02", 0.35)]),
         rad("light", CX, VY, (lb - lt) * 0.62, [(0, "#FFFFFF", 1), (0.5, "#FFE38F", 1), (1, "#FFB940", 1)]),
         blur("b6", 6), blur("b12", 12), blur("b20", 20), blur("b32", 32),
         f'<clipPath id="body"><path d="{sq}"/></clipPath>',
         f'<clipPath id="rim"><path d="{FRAME}{arch(1)}" clip-rule="evenodd"/></clipPath>']
    for i in range(N - 1):
        d.append(lin(f"r{i}", box(K ** i)[1], box(K ** i)[3], [(0, RINGS[i][0], 1), (1, RINGS[i][1], 1)]))
        _, b1, b0 = floor(i)
        d.append(lin(f"f{i}", b1, b0, [(0, FLOORS[i][0], 1), (1, FLOORS[i][1], 1)]))
        d.append(f'<clipPath id="in{i}"><path d="{arch(K ** i)}"/></clipPath>')
    d.append("</defs>")
    o = []
    if layer == "full":
        o.append(f'<g id="background"><path d="{sq}" fill="url(#bg)"/><path d="{sq}" fill="url(#dome)"/><path d="{sq}" fill="url(#glow)"/></g>')
        # Soft shadow of the raised arch, falling down onto the body.
        o.append(f'<g id="shadow" clip-path="url(#body)"><path d="{FRAME}" transform="translate(0 26)" fill="#05030C" fill-opacity="0.55" filter="url(#b32)"/>'
                 f'<path d="{FRAME}" transform="translate(0 8)" fill="#05030C" fill-opacity="0.35" filter="url(#b6)"/></g>')
    if layer in ("full", "tunnel", "mark"):
        o.append('<g id="tunnel">')
        # Interior first: walls, then floors, then the shadow the frame casts into the opening.
        for i in range(N - 1):
            o.append(f'<path d="{arch(K ** i)}" fill="url(#r{i})"/>')
        for i in range(N - 1):
            o.append(f'<path d="{floor(i)[0]}" fill="url(#f{i})"/>')
        o.append(f'<g clip-path="url(#in0)"><path d="{arch(1, False)}" fill="none" stroke="#1A0702" stroke-opacity="0.65" stroke-width="56" filter="url(#b20)"/></g>')
        # The frame: a rounded band of constant thickness standing on the ground line.
        mid = shape(W0 / 2 - RIM / 2, T0 + RIM / 2, B0 + 40, False)
        o.append(f'<path d="{FRAME}{arch(1)}" fill="url(#frame)" fill-rule="evenodd"/>')
        o.append(f'<g clip-path="url(#rim)"><path d="{shape(W0 / 2, T0, B0 + 40, False)}" fill="none" stroke="#3A1204" stroke-opacity="0.45" stroke-width="34" filter="url(#b12)"/>'
                 f'<path d="{shape(P_HW, P_T, B0 + 40, False)}" fill="none" stroke="#3A1204" stroke-opacity="0.5" stroke-width="30" filter="url(#b12)"/>'
                 f'<path d="{mid}" fill="none" stroke="url(#sheen)" stroke-width="16" filter="url(#b6)"/>'
                 f'<rect x="0" y="{f(B0 - 90)}" width="{C}" height="90" fill="url(#foot)"/>'
                 # Glass finish: a crisp specular line just inside the outer edge, and light from the
                 # tunnel caught along the inner edge.
                 f'<path d="{shape(W0 / 2 - 7, T0 + 7, B0 + 40, False)}" fill="none" stroke="url(#spec)" stroke-width="5" filter="url(#b2)"/>'
                 f'<path d="{shape(P_HW + 5, P_T - 5, B0 + 40, False)}" fill="none" stroke="url(#refr)" stroke-width="4" filter="url(#b2)"/></g>')
        o.append("</g>")
    if layer in ("full", "light", "mark"):
        o.append('<g id="light-end">')
        o.append(f'<g clip-path="url(#in0)"><path d="{arch(K ** (N - 1) * 1.12)}" fill="#FFC861" fill-opacity="0.55" filter="url(#b32)"/></g>')
        o.append(f'<path d="{arch(K ** (N - 1))}" fill="url(#light)"/></g>')
    if layer == "full":
        o.append(f'<path d="{sq}" fill="none" stroke="url(#edge)" stroke-width="10" clip-path="url(#body)"/>')
    return d, o

def write(name, layer, view=None):
    d, o = svg(layer)
    x, y, w, h = view or (0, 0, C, C)
    open(name, "w").write(f'<svg xmlns="http://www.w3.org/2000/svg" width="{f(w)}" height="{f(h)}" viewBox="{f(x)} {f(y)} {f(w)} {f(h)}">\n'
                          + "\n".join(d + o) + "\n</svg>\n")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--layers", metavar="DIR", help="also write the tunnel and light layers, e.g. for Icon Composer")
    args = parser.parse_args()
    write(os.path.join(ROOT, "Resources", "AppIcon.svg"), "full")
    pad = 24
    write(os.path.join(ROOT, "docs", "images", "burrow-mark.svg"), "mark",
          (CX - W0 / 2 - pad, T0 - pad, W0 + 2 * pad, H0 + 2 * pad))
    if args.layers:
        os.makedirs(args.layers, exist_ok=True)
        write(os.path.join(args.layers, "tunnel.svg"), "tunnel")
        write(os.path.join(args.layers, "light.svg"), "light")
