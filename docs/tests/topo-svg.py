#!/usr/bin/env python3
# topo-svg.py - render a suite topology spec (JSON) as an SVG tree.
#
# Usage: topo-svg.py spec.json out.svg
#
# Spec:
#   {
#     "title":   "t5 - two endpoints, one switch",
#     "windows": ["fmw.0: BI, 4G, ig 4k -> cxl.1"],          # optional
#     "nodes": [
#       {"id": "hb",   "kind": "hb",  "label": "pxb-cxl cxl.1"},
#       {"id": "rp0",  "kind": "rp",  "label": "cxl-rp rp0", "parent": "hb",
#        "note": "Forward  nr_bi=2"},
#       {"id": "mem0", "kind": "ep",  "label": "cxl-type3 mem0", "parent": "dsp0",
#        "note": "hdm-db"}
#     ]
#   }
# kinds: hb rp usp dsp ep accel. "note" is a second, smaller line.
# Roots are nodes without a parent; several roots are laid out side by side.

import json
import sys

BOX_W, BOX_H, GAP_X, GAP_Y = 196, 46, 16, 34
FILL = {
    "hb": "#e8eef7", "rp": "#dcebdc", "usp": "#f3e8d8", "dsp": "#f3e8d8",
    "ep": "#f7e3e3", "accel": "#efe0f5",
}
STROKE = {
    "hb": "#4a6fa5", "rp": "#3d7a3d", "usp": "#a5692b", "dsp": "#a5692b",
    "ep": "#a53d3d", "accel": "#7a3da5",
}


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def main():
    spec = json.load(open(sys.argv[1]))
    nodes = {n["id"]: dict(n, children=[]) for n in spec["nodes"]}
    roots = []
    for n in spec["nodes"]:
        p = n.get("parent")
        if p:
            nodes[p]["children"].append(nodes[n["id"]])
        else:
            roots.append(nodes[n["id"]])

    def leaves(n):
        return max(1, sum(leaves(c) for c in n["children"]))

    def depth(n):
        return 1 + max((depth(c) for c in n["children"]), default=0)

    # x placement by leaf count, y by depth
    x = 0
    pos = {}

    def place(n, d, x0):
        w = leaves(n) * (BOX_W + GAP_X)
        cx = x0 + w / 2
        pos[n["id"]] = (cx, d)
        cx0 = x0
        for c in n["children"]:
            cw = leaves(c) * (BOX_W + GAP_X)
            place(c, d + 1, cx0)
            cx0 += cw
        return w

    for r in roots:
        x += place(r, 0, x) + GAP_X

    header = [spec.get("title", "")] + spec.get("windows", [])
    top = 14 + 18 * len(header) + 10
    total_w = max(x, 420) + 20
    total_h = top + max(depth(r) for r in roots) * (BOX_H + GAP_Y) + 10

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{int(total_w)}" '
           f'height="{int(total_h)}" viewBox="0 0 {int(total_w)} {int(total_h)}" '
           f'font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="12">',
           f'<rect width="100%" height="100%" fill="white"/>']
    for i, line in enumerate(header):
        weight = ' font-weight="bold"' if i == 0 else ''
        out.append(f'<text x="12" y="{20 + 18 * i}"{weight}>{esc(line)}</text>')

    def xy(nid):
        cx, d = pos[nid]
        return cx + 10, top + d * (BOX_H + GAP_Y)

    for n in nodes.values():
        for c in n["children"]:
            x1, y1 = xy(n["id"])
            x2, y2 = xy(c["id"])
            out.append(f'<path d="M{x1:.0f},{y1 + BOX_H:.0f} C{x1:.0f},{y1 + BOX_H + GAP_Y / 2:.0f} '
                       f'{x2:.0f},{y2 - GAP_Y / 2:.0f} {x2:.0f},{y2:.0f}" '
                       f'stroke="#777" fill="none" stroke-width="1.4"/>')
    for n in nodes.values():
        cx, y = xy(n["id"])
        k = n.get("kind", "ep")
        out.append(f'<rect x="{cx - BOX_W / 2:.0f}" y="{y:.0f}" width="{BOX_W}" height="{BOX_H}" rx="7" '
                   f'fill="{FILL.get(k, "#eee")}" stroke="{STROKE.get(k, "#555")}" stroke-width="1.5"/>')
        out.append(f'<text x="{cx:.0f}" y="{y + 19:.0f}" text-anchor="middle" font-weight="bold">'
                   f'{esc(n["label"])}</text>')
        if n.get("note"):
            out.append(f'<text x="{cx:.0f}" y="{y + 36:.0f}" text-anchor="middle" font-size="11" '
                       f'fill="#333">{esc(n["note"])}</text>')
    out.append("</svg>")
    open(sys.argv[2], "w").write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
