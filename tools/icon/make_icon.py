"""Draws the Synapse app icon: a small neural graph (nodes + glowing links) on a deep violet gradient.
usage: python tools/icon/make_icon.py  ->  Synapse/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"""
import math, os, random
from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "Synapse", "Resources", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def main():
    img = Image.new("RGB", (S, S))
    top, bottom = (40, 22, 92), (110, 86, 207)
    px = img.load()
    for y in range(S):
        for x in range(S):
            t = (0.65 * y + 0.35 * x) / S
            px[x, y] = lerp(top, bottom, min(1, t))

    rnd = random.Random(7)
    cx, cy = S / 2, S / 2
    # Nodes: a central hub, an inner ring and an outer ring.
    nodes = [(cx, cy, 70)]
    for i in range(5):
        a = -math.pi / 2 + i * 2 * math.pi / 5
        nodes.append((cx + 235 * math.cos(a), cy + 235 * math.sin(a), 40))
    for i in range(7):
        a = -math.pi / 2 + (i + 0.5) * 2 * math.pi / 7
        r = 395 + rnd.uniform(-12, 12)
        nodes.append((cx + r * math.cos(a), cy + r * math.sin(a), 24))
    links = [(0, i) for i in range(1, 6)]
    links += [(i, 1 + i % 5) for i in range(1, 6)]
    for j in range(6, 13):
        a = math.atan2(nodes[j][1] - cy, nodes[j][0] - cx)
        best = min(range(1, 6), key=lambda k: abs(math.atan2(nodes[k][1] - cy, nodes[k][0] - cx) - a) % (2 * math.pi))
        links.append((best, j))
    links += [(6, 7), (9, 10), (11, 12)]

    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    for a, b in links:
        g.line([nodes[a][:2], nodes[b][:2]], fill=(190, 170, 255, 255), width=34)
    for x, y, r in nodes:
        g.ellipse([x - r * 1.9, y - r * 1.9, x + r * 1.9, y + r * 1.9], fill=(170, 150, 255, 255))
    glow = glow.filter(ImageFilter.GaussianBlur(38))
    img.paste(Image.new("RGB", (S, S), (200, 185, 255)), (0, 0), glow.split()[3].point(lambda v: int(v * 0.55)))

    d = ImageDraw.Draw(img)
    for a, b in links:
        d.line([nodes[a][:2], nodes[b][:2]], fill=(236, 230, 255), width=14)
    for i, (x, y, r) in enumerate(nodes):
        d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255))
        if i == 0:
            d.ellipse([x - r * 0.45, y - r * 0.45, x + r * 0.45, y + r * 0.45], fill=(110, 86, 207))
    img.save(OUT, "PNG")
    print("wrote", os.path.normpath(OUT))

if __name__ == "__main__":
    main()
