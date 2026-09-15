#!/usr/bin/env python3
"""Generate the ER-failover lab architecture diagram (.drawio + .svg) from one model.

Both artifacts are emitted from the same tables so they can never drift.

  * .drawio  - Azure nodes use draw.io's official Azure Architecture Icon *image*
               library (``image=img/lib/azure2/...``); GCP nodes use the
               ``mxgraph.gcp2`` vector stencils. Azure2 is NOT a stencil set, so
               ``shape=mxgraph.azure2.*`` silently renders as a blank box - that
               was the original icon bug.
  * .svg     - the same official icon artwork, inlined from ``icons_data.py``, so
               the file renders on GitHub with no external assets (GitHub's SVG
               sanitiser strips <script>, external refs and web fonts).

Regenerate:
    python gen_diagram.py            # writes next to this script
    OUT_DIR=/some/dir python gen_diagram.py
"""
import html
import os
import re

from icons_data import ICONS

W, H = 1660, 820
FONT = "Segoe UI,Roboto,Helvetica Neue,Arial,sans-serif"

AZ_BLUE, AZ_DARK, AZ_PURPLE, AZ_VM = "#0078D4", "#0B5394", "#742774", "#773ADC"
GCP_BLUE, MP_RED = "#4285F4", "#E31937"

ICON = 56
LBL = (16, 30, 44)  # label baselines below the icon, one per line

# id, x, y, w, h, title, stroke, fill, dashed
ZONES = [
    ("zgcp",   40, 130,  270, 500, "Google Cloud  ·  us-south1",            GCP_BLUE, "#F6FAFF", False),
    ("zvpc",   58, 166,  234, 152, "VPC erfo-onprem  ·  10.100.0.0/24",     GCP_BLUE, "#FFFFFF", True),

    ("zmp",   350, 130,  190, 500, "Megaport",                              MP_RED,   "#FFF8F6", False),

    ("zaz",   580, 110, 1030, 620, "Microsoft Azure  ·  DMAUSER-FDPO",      AZ_BLUE,  "#FAFCFE", False),
    ("zvwan", 780, 150,  420, 560, "Virtual WAN  ·  erfo-vwan  ·  branch-to-branch enabled",
                                                                            AZ_DARK,  "#EFF6FC", False),
    ("zra",   800, 190,  380, 200, "West US 2",                             "#8A8886", "#FFFFFF", True),
    ("zrb",   800, 470,  380, 200, "South Central US",                      "#8A8886", "#FFFFFF", True),

    ("zva",  1250, 190,  320, 200, "erfo-spoke-wus2  ·  10.10.0.0/24",      AZ_BLUE,  "#F3F9FF", False),
    ("zsa",  1268, 214,  284, 164, "subnet main  ·  10.10.0.0/27",          "#8A8886", "#FFFFFF", True),
    ("zvb",  1250, 470,  320, 200, "erfo-spoke-scus  ·  10.20.0.0/24",      AZ_BLUE,  "#F3F9FF", False),
    ("zsb",  1268, 494,  284, 164, "subnet main  ·  10.20.0.0/27",          "#8A8886", "#FFFFFF", True),
]

# Shape reference for the .drawio file.
#   ("img", "<category>/<File>.svg")  -> Azure Architecture Icon image library
#   ("stencil", "gcp2.<shape_name>")  -> mxgraph vector stencil, tinted by fillColor
#   None                              -> plain styled box (Megaport ships no stencil)
AZ_ER = ("img", "networking/ExpressRoute_Circuits.svg")
AZ_GW = ("img", "networking/Virtual_Network_Gateways.svg")
AZ_HUB = ("img", "networking/Virtual_WAN_Hub.svg")
AZ_VMI = ("img", "compute/Virtual_Machine.svg")

# id, cx, icon-top-y, svg icon key, colour, drawio shape, label lines
NODES = [
    ("gvm",   175, 200, "gcp_vm",       GCP_BLUE,  ("stencil", "gcp2.compute_engine"),
     ["erfo-onprem-vm", "10.100.0.10"]),
    ("grtr",  175, 330, "gcp_router",   GCP_BLUE,  ("stencil", "gcp2.cloud_router"),
     ["Cloud Router  ·  AS 16550", "advertises 10.0.0.0/8"]),
    ("gatt",  175, 470, "gcp_intercon", GCP_BLUE,  ("stencil", "gcp2.partner_interconnect"),
     ["Partner Interconnect", "VLAN 3033", "169.254.40.248/29"]),

    ("mcr",   445, 330, "mcr",          MP_RED,    None,
     ["Megaport MCR", "AS 65001"]),

    ("cchi",  680, 232, "az_er",        AZ_PURPLE, AZ_ER,
     ["erfo-er-chicago", "Chicago  ·  50 Mbps", "169.254.171.248/30"]),
    ("cdal",  680, 512, "az_er",        AZ_PURPLE, AZ_ER,
     ["erfo-er-dallas", "Dallas  ·  50 Mbps", "169.254.172.16/30"]),

    ("gwa",   880, 232, "az_gw",        AZ_BLUE,   AZ_GW,
     ["ER Gateway", "erfo-erconn-chicago"]),
    ("huba", 1090, 232, "az_hub",       AZ_DARK,   AZ_HUB,
     ["erfo-hub-wus2", "10.0.0.0/23", "routing pref ASPath"]),
    ("vma",  1410, 232, "az_vm",        AZ_VM,     AZ_VMI,
     ["erfo-vm-wus2", "10.10.0.4", "no public IP"]),

    ("gwb",   880, 512, "az_gw",        AZ_BLUE,   AZ_GW,
     ["ER Gateway", "erfo-erconn-dallas"]),
    ("hubb", 1090, 512, "az_hub",       AZ_DARK,   AZ_HUB,
     ["erfo-hub-scus", "10.1.0.0/23", "routing pref ASPath"]),
    ("vmb",  1410, 512, "az_vm",        AZ_VM,     AZ_VMI,
     ["erfo-vm-scus", "10.20.0.4", "no public IP"]),
]

EDGES = [
    ("gvm",  "b", "grtr", "t", "",                "solid", None),
    ("grtr", "b", "gatt", "t", "",                "solid", None),
    ("gatt", "r", "mcr",  "l", "",                "solid", ("h", 328)),
    ("mcr",  "r", "cchi", "l", "VXC",             "solid", ("h", 560)),
    ("mcr",  "r", "cdal", "l", "VXC",             "solid", ("h", 560)),
    ("cchi", "r", "gwa",  "l", "private peering", "solid", None),
    ("cdal", "r", "gwb",  "l", "private peering", "solid", None),
    ("gwa",  "r", "huba", "l", "",                "solid", None),
    ("gwb",  "r", "hubb", "l", "",                "solid", None),
    ("huba", "r", "vma",  "l", "VNet connection", "solid", None),
    ("hubb", "r", "vmb",  "l", "VNet connection", "solid", None),
    # Runs down the left of the hubs: a centred vertical would strike through the
    # hub name/prefix labels that sit directly under each icon.
    ("huba", ("l", 0.88), "hubb", ("l", 0.12), "", "both", ("h", 1020)),
]

LEGEND = [(GCP_BLUE, "Google Cloud"), (MP_RED, "Megaport"), (AZ_PURPLE, "ExpressRoute"),
          (AZ_BLUE, "Azure networking"), (AZ_DARK, "Virtual WAN hub"), (AZ_VM, "Virtual machine")]


def esc(s):
    return html.escape(s, quote=True)


def icon_box(key):
    """Natural width/height for an icon scaled to fit the ICON square."""
    vbw, vbh, _ = ICONS[key]
    s = ICON / max(vbw, vbh)
    return vbw * s, vbh * s


NODE_BY_ID = {n[0]: n for n in NODES}


def bounds(nid):
    """Actual drawn rectangle of a node: (x, y, w, h).

    Icons keep their native aspect ratio inside the ICON square, so a node is
    rarely a full 56x56 - edges must attach to the real box or they visibly
    overshoot into the artwork.
    """
    _, cx, top, key, _, shape, _ = NODE_BY_ID[nid]
    if shape is None:
        return cx - 60.0, float(top), 120.0, float(ICON)
    w, h = icon_box(key)
    return cx - w / 2.0, top + (ICON - h) / 2.0, w, h


SIDES = {"l": (0.0, 0.5), "r": (1.0, 0.5), "t": (0.5, 0.0), "b": (0.5, 1.0)}


def side_parts(side):
    """A side is either "l"/"r"/"t"/"b" or ("l", frac) to slide along that edge."""
    return side if isinstance(side, tuple) else (side, 0.5)


def side_frac(side):
    """Style fractions draw.io wants for exitX/exitY and entryX/entryY."""
    name, f = side_parts(side)
    return {"l": (0.0, f), "r": (1.0, f), "t": (f, 0.0), "b": (f, 1.0)}[name]


def anchor(nid, side):
    x, y, w, h = bounds(nid)
    fx, fy = side_frac(side)
    return round(x + w * fx, 2), round(y + h * fy, 2)


def route(src, sside, dst, dside, via):
    """Strictly orthogonal polyline between two node anchors.

    Every segment is axis-aligned; nothing is left to a renderer's own routing,
    so the .svg and the .drawio trace identical paths.
    """
    p0, p1 = anchor(src, sside), anchor(dst, dside)
    if via is None:
        # Aligned row or column: keep the source's axis so the line stays straight.
        if side_parts(sside)[0] in "lr":
            return [p0, (p1[0], p0[1])]
        return [p0, (p0[0], p1[1])]
    axis, at = via
    if axis == "h":            # leave sideways, jog vertically at x = at, arrive sideways
        return [p0, (at, p0[1]), (at, p1[1]), p1]
    return [p0, (p0[0], at), (p1[0], at), p1]   # leave vertically, jog horizontally at y = at


def label_anchor(pts):
    """Midpoint of the polyline's longest segment.

    Anchoring on a vertex instead drops the label on top of the node the edge
    terminates at, which is what the earlier revision did.
    """
    best, bx, by = -1.0, pts[0][0], pts[0][1]
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        d = abs(x2 - x1) + abs(y2 - y1)
        if d > best:
            best, bx, by = d, (x1 + x2) / 2.0, (y1 + y2) / 2.0
    return bx, by


# --------------------------------------------------------------- SVG icons
_ID = re.compile(r'id="([^"]+)"')


def uniquify(frag, suffix):
    """Suffix every id (and its url(#…)/href="#…" references) in one fragment.

    The same icon is used by more than one node, so without this the exported SVG
    would carry duplicate gradient/clipPath ids - invalid, and fragile in renderers.
    """
    for old in set(_ID.findall(frag)):
        new = "%s_%s" % (old, suffix)
        frag = (frag.replace('id="%s"' % old, 'id="%s"' % new)
                    .replace("url(#%s)" % old, "url(#%s)" % new)
                    .replace('href="#%s"' % old, 'href="#%s"' % new))
    return frag


def icon(key, cx, top, colour, suffix):
    """Official product icon, scaled into the ICON square and centred at cx."""
    vbw, vbh, frag = ICONS[key]
    s = ICON / max(vbw, vbh)
    x = cx - vbw * s / 2
    y = top + (ICON - vbh * s) / 2
    frag = uniquify(frag.replace("CURRENT", colour), suffix)
    return ('<g transform="translate(%.2f,%.2f) scale(%.4f)">%s</g>' % (x, y, s, frag))


def mcr_glyph(cx, top):
    """Megaport ships no draw.io stencil, so the MCR keeps a branded hexagon."""
    x, y, w = cx - ICON // 2, top, "#FFFFFF"
    return ('<g transform="translate(%d,%d)">'
            '<path d="M28 2 L50 15 V41 L28 54 L6 41 V15 Z" fill="url(#gmp)"/>'
            '<path d="M16 38 V19 l12 12 12 -12 v19" stroke="%s" stroke-width="4.5" fill="none" '
            'stroke-linecap="round" stroke-linejoin="round"/></g>' % (x, y, w))


def defs():
    return ('<defs>'
            '<marker id="arrEnd" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
            'markerHeight="7" orient="auto-start-reverse">'
            '<path d="M0,0 L10,5 L0,10 z" fill="#4A4A4A"/></marker>'
            '<marker id="arrStart" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="7" '
            'markerHeight="7" orient="auto">'
            '<path d="M10,0 L0,5 L10,10 z" fill="#4A4A4A"/></marker>'
            '<linearGradient id="gmp" x1="0" y1="0" x2="0" y2="1">'
            '<stop offset="0" stop-color="#FF6A5A"/><stop offset="1" stop-color="#E31937"/>'
            '</linearGradient></defs>')


def svg():
    o = ['<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
         'width="%d" height="%d" viewBox="0 0 %d %d" font-family="%s">' % (W, H, W, H, FONT),
         defs(),
         '<rect width="%d" height="%d" fill="#FFFFFF"/>' % (W, H),
         '<text x="40" y="48" font-size="25" font-weight="600" fill="#1B1B1B">'
         'ExpressRoute Failover Across Two Virtual WAN Hubs</text>',
         '<text x="40" y="76" font-size="13.5" fill="#605E5C">'
         'Two Megaport circuits  ·  hubRoutingPreference = ASPath  ·  hub-to-hub transit  ·  '
         'GCP on-premises simulator advertising 10.0.0.0/8</text>',
         '<line x1="40" y1="94" x2="%d" y2="94" stroke="#E1DFDD"/>' % (W - 40)]

    for _, x, y, w, h, title, stroke, fill, dashed in ZONES:
        d = ' stroke-dasharray="6 4"' if dashed else ''
        o.append('<rect x="%d" y="%d" width="%d" height="%d" rx="10" fill="%s" '
                 'stroke="%s" stroke-width="1.5"%s/>' % (x, y, w, h, fill, stroke, d))
        o.append('<text x="%d" y="%d" font-size="11.5" font-weight="600" fill="%s">%s</text>'
                 % (x + 14, y + 21, stroke, esc(title)))

    for src, sside, dst, dside, label, style, via in EDGES:
        pts = route(src, sside, dst, dside, via)
        d = " ".join("%s%.2f,%.2f" % ("M" if i == 0 else "L", px, py)
                     for i, (px, py) in enumerate(pts))
        dash = ' stroke-dasharray="7 4"' if style == "both" else ''
        mk = ' marker-end="url(#arrEnd)"' + (' marker-start="url(#arrStart)"' if style == "both" else '')
        o.append('<path d="%s" fill="none" stroke="#4A4A4A" stroke-width="1.6" '
                 'stroke-linejoin="round"%s%s/>' % (d, dash, mk))
        if label:
            mx, my = label_anchor(pts)
            wpx = len(label) * 5.0 + 8
            o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="13" rx="2" fill="#FFFFFF"/>'
                     % (mx - wpx / 2, my - 19, wpx))
            o.append('<text x="%.1f" y="%.1f" font-size="9.5" text-anchor="middle" '
                     'fill="#605E5C">%s</text>' % (mx, my - 9, esc(label)))
            mx, my = label_anchor(pts)
            wpx = len(label) * 5.0 + 8
            o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="13" rx="2" fill="#FFFFFF"/>'
                     % (mx - wpx / 2, my - 19, wpx))
            o.append('<text x="%.1f" y="%.1f" font-size="9.5" text-anchor="middle" '
                     'fill="#605E5C">%s</text>' % (mx, my - 9, esc(label)))

    for nid, cx, y, key, colour, _shape, lines in NODES:
        o.append(mcr_glyph(cx, y) if key == "mcr" else icon(key, cx, y, colour, nid))
        for i, ln in enumerate(lines[:3]):
            fs, fw, op = (11.5, "600", 1) if i == 0 else (9.5, "400", 0.8)
            o.append('<text x="%d" y="%d" font-size="%s" font-weight="%s" text-anchor="middle" '
                     'fill="#323130" opacity="%s">%s</text>'
                     % (cx, y + ICON + LBL[i], fs, fw, op, esc(ln)))

    o.append('<text x="1028" y="410" font-size="10.5" font-weight="600" fill="#0B5394">hub-to-hub</text>')
    o.append('<text x="1028" y="424" font-size="10.5" font-weight="600" fill="#0B5394">transit</text>')

    lx = 40
    for colour, text in LEGEND:
        o.append('<rect x="%d" y="%d" width="14" height="14" rx="3" fill="%s"/>' % (lx, H - 58, colour))
        o.append('<text x="%d" y="%d" font-size="11" fill="#323130">%s</text>'
                 % (lx + 21, H - 46, esc(text)))
        lx += 34 + len(text) * 6.4

    o.append('<text x="40" y="%d" font-size="10.5" fill="#8A8886">'
             'Each hub prefers its local circuit. When one circuit drops, 10.0.0.0/8 is relearned over '
             'hub-to-hub transit with a longer AS path, and ASPath routing preference installs it.</text>'
             % (H - 22))
    o.append('</svg>')
    return "\n".join(o)


# ------------------------------------------------------------------ drawio
LABEL_BELOW = "labelPosition=center;verticalLabelPosition=bottom;verticalAlign=top;align=center;"

# Azure Architecture Icons are full-colour images - no fillColor, no stencil.
AZ_STYLE = ("image;aspect=fixed;html=1;points=[];outlineConnect=0;fontSize=10;fontStyle=0;"
            "fontColor=#323130;" + LABEL_BELOW + "image=img/lib/azure2/%s;")
# GCP shapes are monochrome vector stencils tinted by fillColor.
GCP_STYLE = ("sketch=0;html=1;aspect=fixed;strokeColor=none;fontSize=10;fontStyle=0;"
             "fontColor=#323130;" + LABEL_BELOW + "fillColor=%s;shape=mxgraph.%s;")


def drawio():
    c = ['<mxfile host="app.diagrams.net" type="device">',
         '<diagram id="erfo" name="ER failover architecture">',
         '<mxGraphModel dx="1600" dy="960" grid="1" gridSize="10" page="1" '
         'pageWidth="%d" pageHeight="%d" math="0" shadow="0"><root>'
         '<mxCell id="0"/><mxCell id="1" parent="0"/>' % (W, H)]

    def cell(cid, style, label, x, y, w, h):
        c.append('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1">'
                 '<mxGeometry x="%s" y="%s" width="%s" height="%s" as="geometry"/></mxCell>'
                 % (cid, label, style, x, y, w, h))

    cell("t1", "text;html=1;align=left;verticalAlign=middle;fontSize=25;fontStyle=1;fontColor=#1B1B1B;",
         esc("ExpressRoute Failover Across Two Virtual WAN Hubs"), 40, 26, 980, 32)
    cell("t2", "text;html=1;align=left;verticalAlign=middle;fontSize=13;fontColor=#605E5C;",
         esc("Two Megaport circuits · hubRoutingPreference = ASPath · hub-to-hub transit · "
             "GCP on-premises simulator advertising 10.0.0.0/8"), 40, 62, 1300, 22)

    for zid, x, y, w, h, title, stroke, fill, dashed in ZONES:
        cell(zid, "rounded=1;html=1;whiteSpace=wrap;align=left;verticalAlign=top;spacingLeft=12;"
                  "spacingTop=4;fontSize=11;fontStyle=1;dashed=%d;fillColor=%s;strokeColor=%s;"
                  "fontColor=%s;" % (1 if dashed else 0, fill, stroke, stroke),
             esc(title), x, y, w, h)

    for nid, cx, y, key, colour, shape, lines in NODES:
        label = esc("<b>" + lines[0] + "</b>" + "".join("<br/>" + ln for ln in lines[1:]))
        if shape is None:
            cell(nid, "rounded=1;html=1;whiteSpace=wrap;align=center;verticalAlign=middle;"
                      "fontSize=10;fillColor=#FBE9E7;strokeColor=%s;fontColor=#8C2A13;" % colour,
                 label, cx - 60, y, 120, ICON)
            continue
        kind, ref = shape
        style = AZ_STYLE % ref if kind == "img" else GCP_STYLE % (colour, ref)
        # Keep each icon's native aspect ratio so it is not letterboxed in draw.io.
        w, h = icon_box(key)
        cell(nid, style, label, round(cx - w / 2, 2), round(y + (ICON - h) / 2, 2),
             round(w, 2), round(h, 2))

    for i, (src, sside, dst, dside, label, style, via) in enumerate(EDGES):
        extra = "dashed=1;startArrow=classic;startFill=1;" if style == "both" else ""
        ex, ey = side_frac(sside)
        nx, ny = side_frac(dside)
        pts = route(src, sside, dst, dside, via)
        way = "".join('<mxPoint x="%.2f" y="%.2f"/>' % (px, py) for px, py in pts[1:-1])
        # Bind to the real cells and pin the exit/entry sides so draw.io cannot
        # re-route the edge into a diagonal or clip it through the icon.
        c.append('<mxCell id="e%d" value="%s" style="edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;'
                 'exitX=%s;exitY=%s;exitDx=0;exitDy=0;entryX=%s;entryY=%s;entryDx=0;entryDy=0;'
                 '%sstrokeColor=#4A4A4A;strokeWidth=1.6;fontSize=9;fontColor=#605E5C;'
                 'labelBackgroundColor=#FFFFFF;endArrow=classic;endFill=1;" edge="1" parent="1" '
                 'source="%s" target="%s">'
                 '<mxGeometry relative="1" as="geometry">'
                 '<Array as="points">%s</Array></mxGeometry></mxCell>'
                 % (i, esc(label), ex, ey, nx, ny, extra, src, dst, way))

    cell("h2h", "text;html=1;align=left;verticalAlign=middle;fontSize=10;fontStyle=1;fontColor=#0B5394;",
         esc("hub-to-hub<br/>transit"), 1026, 398, 100, 34)
    cell("foot", "text;html=1;align=left;verticalAlign=middle;fontSize=10;fontColor=#8A8886;",
         esc("Each hub prefers its local circuit. When one circuit drops, 10.0.0.0/8 is relearned over "
             "hub-to-hub transit with a longer AS path, and ASPath routing preference installs it."),
         40, H - 34, 1400, 22)

    c.append('</root></mxGraphModel></diagram></mxfile>')
    return "\n".join(c)


if __name__ == "__main__":
    base = os.environ.get("OUT_DIR", os.path.dirname(os.path.abspath(__file__)))
    os.makedirs(base, exist_ok=True)
    for name, data in (("er-failover-architecture.svg", svg()),
                       ("er-failover-architecture.drawio", drawio())):
        path = os.path.join(base, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(data)
        print("wrote", path, len(data), "bytes")
