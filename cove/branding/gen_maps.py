#!/usr/bin/env python3
"""Proper treasure-map variations of the `>heart cove` icon.
Base (terminal + cyan prompt + pink heart + amber 'cove') is identical; only the
treasure map accessory changes -- from low-poly ellipse to a real pirate map."""
import subprocess, pathlib

OUT = pathlib.Path(__file__).parent / "maps"
OUT.mkdir(exist_ok=True)

DEFS = '''
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#1c2a33"/><stop offset="55%" stop-color="#16212a"/><stop offset="100%" stop-color="#101820"/>
    </linearGradient>
    <linearGradient id="ring" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#9fe9ff"/><stop offset="100%" stop-color="#4bb8e6"/>
    </linearGradient>
    <radialGradient id="parch" cx="42%" cy="38%" r="75%">
      <stop offset="0%" stop-color="#f6e8bd"/><stop offset="70%" stop-color="#ecd79f"/><stop offset="100%" stop-color="#d8b673"/>
    </radialGradient>
    <linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#ffe89a"/><stop offset="52%" stop-color="#f2bd48"/><stop offset="100%" stop-color="#c17f24"/>
    </linearGradient>
    <filter id="soft" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="9"/></filter>
    <filter id="drop" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="4" stdDeviation="5" flood-color="#000" flood-opacity="0.35"/>
    </filter>
  </defs>
'''

CARD = '''
  <rect width="512" height="512" rx="112" fill="url(#bg)"/>
  <ellipse cx="256" cy="252" rx="150" ry="150" fill="#63d6ff" opacity="0.15" filter="url(#soft)"/>
  <rect x="96" y="126" width="320" height="260" rx="40" fill="url(#ring)"/>
  <rect x="108" y="138" width="296" height="236" rx="30" fill="#0f1419"/>
  <rect x="108" y="138" width="296" height="52" rx="30" fill="#182029"/>
  <rect x="108" y="168" width="296" height="22" fill="#182029"/>
  <circle cx="140" cy="164" r="9" fill="#ff6f6f"/><circle cx="170" cy="164" r="9" fill="#ffd166"/><circle cx="200" cy="164" r="9" fill="#7ee787"/>
  <path d="M150 236 l46 34 -46 34" stroke="#8fe3ff" stroke-width="20" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M262 250 c-14 -22 -50 -14 -50 14 c0 26 40 46 54 58 c14 -12 54 -32 54 -58 c0 -28 -36 -36 -50 -14 c-2 3 -6 3 -8 0 z" fill="#ff7aa2"/>
  <path d="M292 236 a30 30 0 0 1 8 6" stroke="#ffd0df" stroke-width="7" fill="none" stroke-linecap="round" opacity="0.85"/>
'''

WORDMARK = '''
  <text x="256" y="446" text-anchor="middle" font-family="Menlo, monospace" font-size="66" font-weight="700" fill="#ffe6a3" letter-spacing="4">cove</text>
</svg>
'''

# ---- shared cartography pieces (local coords) ------------------------------
def compass(cx, cy, r):
    return f'''
      <circle cx="{cx}" cy="{cy}" r="{r+4}" fill="none" stroke="#8a6a2e" stroke-width="1.5" opacity="0.6"/>
      <path d="M{cx} {cy-r-5} L{cx+5} {cy-3} L{cx} {cy} L{cx-5} {cy-3} Z" fill="#b23b2e"/>
      <path d="M{cx} {cy+r+5} L{cx+5} {cy+3} L{cx} {cy} L{cx-5} {cy+3} Z" fill="#7a5a2a"/>
      <path d="M{cx-r-5} {cy} L{cx-3} {cy-5} L{cx} {cy} L{cx-3} {cy+5} Z" fill="#7a5a2a"/>
      <path d="M{cx+r+5} {cy} L{cx+3} {cy-5} L{cx} {cy} L{cx+3} {cy+5} Z" fill="#7a5a2a"/>
      <circle cx="{cx}" cy="{cy}" r="2.6" fill="#7a5a2a"/>'''

def xmark(x, y, s=12):
    return f'<path d="M{x-s} {y-s} l{2*s} {2*s} M{x+s} {y-s} l{-2*s} {2*s}" stroke="#c0392b" stroke-width="6.5" stroke-linecap="round"/>'

def dots(d):
    return f'<path d="{d}" stroke="#8a5a2a" stroke-width="3.4" fill="none" stroke-dasharray="0.5 8" stroke-linecap="round"/>'

# torn parchment outline for a W x H sheet (local origin 0,0)
def sheet(W, H):
    return (f'M6 12 L{W*0.26:.0f} 5 L{W*0.5:.0f} 10 L{W*0.74:.0f} 4 L{W-6} 12 '
            f'L{W-4} {H*0.32:.0f} L{W-8} {H*0.62:.0f} L{W-5} {H-10} '
            f'L{W*0.72:.0f} {H-4} L{W*0.48:.0f} {H-8} L{W*0.24:.0f} {H-3} L8 {H-11} '
            f'L4 {H*0.66:.0f} L9 {H*0.4:.0f} L4 {H*0.18:.0f} Z')

def parchment(W, H):
    p = sheet(W, H)
    return (f'<path d="{p}" fill="#a8863f" opacity="0.55" transform="translate(2 3)"/>'
            f'<path d="{p}" fill="url(#parch)" stroke="#b9964e" stroke-width="2.5"/>'
            f'<path d="{p}" fill="none" stroke="#c8a86a" stroke-width="1" opacity="0.7" transform="translate(4 4) scale(0.965)"/>')

# ---- variations ------------------------------------------------------------
# 1. Classic: island coastline + winding route + X + compass, tucked bottom-right
def v1():
    inner = (parchment(150, 120)
        + '<path d="M40 70 q-6 -20 18 -26 q22 -6 30 10 q18 -4 22 14 q14 6 6 22 q-10 16 -34 12 q-30 6 -44 -12 q-8 -18 2 -30 z" fill="#cbe3c9" opacity="0.55" stroke="#7fa982" stroke-width="2"/>'
        + dots('M34 96 q10 -22 34 -20 q26 2 30 -22')
        + compass(120, 30, 12)
        + xmark(98, 52, 10)
        + '<path d="M20 104 q7 -6 14 0 M118 96 q7 -6 14 0" stroke="#7fa7c8" stroke-width="2.5" fill="none" stroke-linecap="round" opacity="0.7"/>')
    return f'<g transform="translate(286 280) rotate(-7)" filter="url(#drop)">{inner}</g>'

# 2. Unrolled scroll with rollers, held horizontally
def v2():
    inner = (parchment(160, 96)
        + dots('M30 66 q16 -30 44 -22 q26 8 40 -24')
        + compass(126, 26, 11)
        + xmark(78, 40, 10)
        + '<path d="M22 78 q7 -6 14 0 M120 74 q7 -6 14 0" stroke="#7fa7c8" stroke-width="2.5" fill="none" stroke-linecap="round" opacity="0.6"/>'
        + '<path d="M40 30 l6 -8 6 8 6 -8 6 8" stroke="#8a6a3a" stroke-width="2.5" fill="none" stroke-linecap="round"/>'  # mountains
        + '<ellipse cx="-2" cy="48" rx="12" ry="54" fill="#d8b673" stroke="#a8863f" stroke-width="3"/>'
        + '<ellipse cx="-2" cy="48" rx="5" ry="54" fill="#c19a56"/>'
        + '<ellipse cx="162" cy="48" rx="12" ry="54" fill="#d8b673" stroke="#a8863f" stroke-width="3"/>'
        + '<ellipse cx="162" cy="48" rx="5" ry="54" fill="#c19a56"/>')
    return f'<g transform="translate(280 288) rotate(-4)" filter="url(#drop)">{inner}</g>'

# 3. Big, prominent map lying across the lower third
def v3():
    inner = (parchment(230, 150)
        + '<path d="M60 96 q-10 -30 26 -40 q34 -10 48 14 q28 -6 34 22 q22 10 8 34 q-16 24 -52 18 q-46 8 -66 -18 q-12 -26 4 -46 z" fill="#cbe3c9" opacity="0.5" stroke="#7fa982" stroke-width="2.5"/>'
        + dots('M46 118 q18 -34 54 -30 q40 4 46 -34')
        + compass(188, 40, 15)
        + xmark(150, 74, 13)
        + '<path d="M30 128 q9 -7 18 0 M182 116 q9 -7 18 0 M92 132 q9 -7 18 0" stroke="#7fa7c8" stroke-width="3" fill="none" stroke-linecap="round" opacity="0.6"/>'
        + '<path d="M70 60 l8 -12 8 12 8 -12 8 12" stroke="#8a6a3a" stroke-width="3" fill="none" stroke-linecap="round"/>')
    return f'<g transform="translate(146 250) rotate(-3)" filter="url(#drop)">{inner}</g>'

# 4. Ornate compass-focused map
def v4():
    inner = (parchment(150, 122)
        + dots('M28 92 q20 -20 40 -8 q22 12 40 -30')
        + '<circle cx="75" cy="60" r="30" fill="none" stroke="#8a6a2e" stroke-width="1.5" opacity="0.5"/>'
        + compass(75, 60, 24)
        + '<text x="75" y="26" text-anchor="middle" font-family="Georgia, serif" font-size="13" font-weight="700" fill="#8a5a2a">N</text>'
        + xmark(120, 96, 9))
    return f'<g transform="translate(286 280) rotate(-6)" filter="url(#drop)">{inner}</g>'

# 5. Cute island isle + palm + waves + X
def v5():
    inner = (parchment(152, 120)
        + '<path d="M30 84 q-4 -18 20 -22 q18 -30 44 -6 q26 -2 26 20 q10 14 -8 22 q-14 12 -44 8 q-34 4 -46 -10 q-4 -8 8 -12 z" fill="#e6cf92" stroke="#b98a4a" stroke-width="2.5"/>'
        + '<path d="M74 52 q-2 -16 4 -22" stroke="#5a7a3a" stroke-width="4" fill="none" stroke-linecap="round"/>'  # palm trunk
        + '<path d="M78 30 q-18 -6 -26 4 q16 -2 26 4 q0 -14 14 -18 q-10 8 -14 10 q14 -2 22 6 q-14 -8 -22 -6 z" fill="#4e8a3a"/>'  # fronds
        + xmark(108, 84, 10)
        + dots('M36 96 q24 -6 40 -2 q22 4 32 -8')
        + compass(122, 30, 11)
        + '<path d="M20 104 q7 -6 14 0 M120 100 q7 -6 14 0 M66 108 q7 -6 14 0" stroke="#7fa7c8" stroke-width="2.5" fill="none" stroke-linecap="round" opacity="0.6"/>')
    return f'<g transform="translate(286 280) rotate(-7)" filter="url(#drop)">{inner}</g>'

# 6. Torn scrap map -- rougher, folded, skull marker
def v6():
    inner = (parchment(148, 118)
        + '<path d="M74 6 L74 112" stroke="#c8a86a" stroke-width="1.5" opacity="0.6" stroke-dasharray="4 4"/>'  # fold
        + '<path d="M6 60 L142 58" stroke="#c8a86a" stroke-width="1.5" opacity="0.6" stroke-dasharray="4 4"/>'
        + dots('M30 40 q26 8 30 34 q4 22 40 24')
        + compass(120, 32, 11)
        + xmark(104, 92, 11)
        + '<g transform="translate(38 34) scale(0.7)"><path d="M-11 -3 a11 13 0 0 1 22 0 v6 q0 6 -6 7 l-1.5 6 h-2.5 l-1.5 -5 h-2 l-1.5 5 h-2.5 l-1.5 -6 q-6 -1 -6 -7 z" fill="#8a5a2a"/><circle cx="-4.5" cy="-1" r="3.3" fill="#ecd79f"/><circle cx="4.5" cy="-1" r="3.3" fill="#ecd79f"/></g>')
    return f'<g transform="translate(288 282) rotate(5)" filter="url(#drop)">{inner}</g>'

VARIANTS = {
    "1-classic": v1(), "2-scroll": v2(), "3-big": v3(),
    "4-compass": v4(), "5-island": v5(), "6-scrap": v6(),
}

for name, acc in VARIANTS.items():
    svg = f'<svg width="512" height="512" viewBox="0 0 512 512" xmlns="http://www.w3.org/2000/svg">{DEFS}{CARD}{acc}{WORDMARK}'
    p = OUT / f"map-{name}.svg"
    p.write_text(svg)
    subprocess.run(["rsvg-convert", "-w", "512", "-h", "512", str(p), "-o", str(OUT / f"map-{name}.png")], check=True)
    print("wrote", p.name)
