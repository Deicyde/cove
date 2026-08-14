#!/usr/bin/env python3
"""Generate pirate-accessory variations of the beloved `>heart cove` icon.
The base (terminal card + cyan prompt + pink heart + amber 'cove') is identical
across all; only the pirate accessory changes."""
import subprocess, pathlib

OUT = pathlib.Path(__file__).parent / "variants"
OUT.mkdir(exist_ok=True)

DEFS = '''
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#1c2a33"/>
      <stop offset="55%" stop-color="#16212a"/>
      <stop offset="100%" stop-color="#101820"/>
    </linearGradient>
    <linearGradient id="ring" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#9fe9ff"/>
      <stop offset="100%" stop-color="#4bb8e6"/>
    </linearGradient>
    <linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#ffe89a"/>
      <stop offset="52%" stop-color="#f2bd48"/>
      <stop offset="100%" stop-color="#c17f24"/>
    </linearGradient>
    <linearGradient id="parch" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#f3e3b0"/>
      <stop offset="100%" stop-color="#d6bb7e"/>
    </linearGradient>
    <linearGradient id="glass" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="#8a5230"/>
      <stop offset="45%" stop-color="#5f3a22"/>
      <stop offset="100%" stop-color="#3f2716"/>
    </linearGradient>
    <linearGradient id="feather" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#b98ad6"/>
      <stop offset="100%" stop-color="#7d51a8"/>
    </linearGradient>
    <linearGradient id="hatg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#3a3550"/>
      <stop offset="100%" stop-color="#221f2e"/>
    </linearGradient>
    <filter id="soft" x="-40%" y="-40%" width="180%" height="180%">
      <feGaussianBlur stdDeviation="9"/>
    </filter>
  </defs>
'''

# terminal card + prompt + heart  (the part she loves — never changes)
CARD = '''
  <rect width="512" height="512" rx="112" fill="url(#bg)"/>
  <ellipse cx="256" cy="252" rx="150" ry="150" fill="#63d6ff" opacity="0.15" filter="url(#soft)"/>

  <rect x="96" y="126" width="320" height="260" rx="40" fill="url(#ring)"/>
  <rect x="108" y="138" width="296" height="236" rx="30" fill="#0f1419"/>
  <rect x="108" y="138" width="296" height="52" rx="30" fill="#182029"/>
  <rect x="108" y="168" width="296" height="22" fill="#182029"/>
  <circle cx="140" cy="164" r="9" fill="#ff6f6f"/>
  <circle cx="170" cy="164" r="9" fill="#ffd166"/>
  <circle cx="200" cy="164" r="9" fill="#7ee787"/>

  <path d="M150 236 l46 34 -46 34" stroke="#8fe3ff" stroke-width="20" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M262 250 c-14 -22 -50 -14 -50 14 c0 26 40 46 54 58 c14 -12 54 -32 54 -58 c0 -28 -36 -36 -50 -14 c-2 3 -6 3 -8 0 z" fill="#ff7aa2"/>
  <path d="M292 236 a30 30 0 0 1 8 6" stroke="#ffd0df" stroke-width="7" fill="none" stroke-linecap="round" opacity="0.85"/>
'''

WORDMARK = '''
  <text x="256" y="446" text-anchor="middle" font-family="Menlo, monospace" font-size="66" font-weight="700" fill="#ffe6a3" letter-spacing="4">cove</text>
</svg>
'''

def skull(cx, cy, s, fill="#f3eede", eye="#221f2e"):
    return f'''<g transform="translate({cx} {cy}) scale({s})">
      <path d="M-11 -3 a11 13 0 0 1 22 0 v6 q0 6 -6 7 l-1.5 6 h-2.5 l-1.5 -5 h-2 l-1.5 5 h-2.5 l-1.5 -6 q-6 -1 -6 -7 z" fill="{fill}"/>
      <circle cx="-4.5" cy="-1" r="3.3" fill="{eye}"/>
      <circle cx="4.5" cy="-1" r="3.3" fill="{eye}"/>
      <path d="M-1.5 6 l1.5 3 1.5 -3 z" fill="{eye}"/>
    </g>'''

# ---- accessories -----------------------------------------------------------

# 1. Jolly Roger pennant flying off the top-right
FLAG = f'''
  <line x1="352" y1="150" x2="352" y2="52" stroke="url(#gold)" stroke-width="8" stroke-linecap="round"/>
  <circle cx="352" cy="50" r="8" fill="url(#gold)"/>
  <path d="M352 60 Q404 52 436 74 Q404 84 436 104 Q404 118 352 108 Z" fill="#20202a"/>
  {skull(392, 84, 1.15, fill='#f3eede', eye='#20202a')}
'''

# 2. Doubloons — a little pile of gold coins at the base
COINS = f'''
  <g>
    <ellipse cx="176" cy="392" rx="70" ry="16" fill="#000" opacity="0.25"/>
    <g stroke="#8a5410" stroke-width="3">
      <ellipse cx="150" cy="378" rx="30" ry="12" fill="url(#gold)"/>
      <ellipse cx="150" cy="372" rx="30" ry="12" fill="url(#gold)"/>
      <ellipse cx="206" cy="382" rx="30" ry="12" fill="url(#gold)"/>
      <ellipse cx="178" cy="360" rx="30" ry="12" fill="url(#gold)"/>
    </g>
    <circle cx="178" cy="360" r="7" fill="#fff2c0" opacity="0.7"/>
    <path d="M300 356 l4 12 12 4 -12 4 -4 12 -4 -12 -12 -4 12 -4 z" fill="#ffe08a"/>
    <path d="M132 336 l3 8 8 3 -8 3 -3 8 -3 -8 -8 -3 8 -3 z" fill="#ffe08a"/>
  </g>
'''

# 3. Treasure map scroll leaning bottom-right
MAP = f'''
  <g transform="rotate(-8 356 356)">
    <rect x="300" y="300" width="112" height="96" rx="8" fill="url(#parch)" stroke="#b9975a" stroke-width="4"/>
    <rect x="292" y="296" width="14" height="104" rx="7" fill="#c9a globalCompositeOperation"/>
  </g>
'''
# (map rewritten cleanly below)
MAP = f'''
  <g transform="rotate(-7 356 350)">
    <rect x="298" y="298" width="116" height="100" rx="10" fill="url(#parch)"/>
    <rect x="298" y="298" width="116" height="100" rx="10" fill="none" stroke="#b9975a" stroke-width="3"/>
    <path d="M312 330 q18 -14 34 4 q16 18 40 -2" stroke="#7a5a2a" stroke-width="3" fill="none" stroke-dasharray="6 7" stroke-linecap="round"/>
    <path d="M382 322 l12 12 M394 322 l-12 12" stroke="#c0392b" stroke-width="5" stroke-linecap="round"/>
    <circle cx="322" cy="372" r="9" fill="none" stroke="#7a5a2a" stroke-width="3"/>
    <path d="M322 366 l0 12 M316 372 l12 0" stroke="#7a5a2a" stroke-width="2"/>
    <ellipse cx="290" cy="348" rx="12" ry="52" fill="#e6cf92" stroke="#b9975a" stroke-width="3"/>
    <ellipse cx="290" cy="348" rx="5" ry="52" fill="#cbaf72"/>
  </g>
'''

# 4. Rum bottle leaning on the right
RUM = f'''
  <g transform="rotate(12 372 330)">
    <ellipse cx="372" cy="404" rx="34" ry="10" fill="#000" opacity="0.22"/>
    <rect x="360" y="252" width="24" height="30" rx="5" fill="#6b4a2f"/>
    <rect x="362" y="244" width="20" height="14" rx="4" fill="#8a6a44"/>
    <path d="M356 282 q-14 10 -14 40 v56 q0 16 16 16 h36 q16 0 16 -16 v-56 q0 -30 -14 -40 z" fill="url(#glass)"/>
    <rect x="348" y="322" width="52" height="46" rx="8" fill="#f1e4c4"/>
    {skull(374, 340, 0.9, fill='#3f2716', eye='#f1e4c4')}
    <path d="M360 356 h28" stroke="#3f2716" stroke-width="3" stroke-linecap="round"/>
    <path d="M350 300 q6 -6 12 -4" stroke="#fff" stroke-width="4" fill="none" stroke-linecap="round" opacity="0.35"/>
  </g>
'''

# 5. Captain's hat, redone — small, jaunty, perched on the top-right corner
HAT = f'''
  <g transform="rotate(12 356 120)">
    <path d="M300 132 q56 -60 96 -80 q-8 46 -34 82 q-22 26 -50 20 z" fill="url(#feather)"/>
    <path d="M356 150
             Q330 96 356 84
             Q382 74 408 92
             Q436 108 430 150
             Q392 168 356 150 Z" fill="url(#hatg)"/>
    <path d="M334 146 Q384 168 428 146" stroke="#e6b85c" stroke-width="7" fill="none" stroke-linecap="round"/>
    {skull(381, 118, 0.85)}
  </g>
'''

# 6. Parrot perched on the top-left corner
PARROT = f'''
  <g>
    <path d="M150 138 q-30 -6 -40 -34 q-4 -22 14 -34 q26 -14 44 8 q14 18 6 44 q-6 18 -24 22 z" fill="#e14b4b"/>
    <path d="M126 96 q-16 6 -18 26 q14 6 26 -6 q6 -12 -8 -20 z" fill="#3fb7e6"/>
    <path d="M124 84 q-8 -14 6 -22 q12 -6 18 6" fill="#ffd166"/>
    <circle cx="132" cy="82" r="14" fill="#e14b4b"/>
    <circle cx="128" cy="80" r="5" fill="#fff"/>
    <circle cx="127" cy="81" r="2.6" fill="#20202a"/>
    <path d="M114 84 q-16 -2 -18 10 q10 8 20 -2 z" fill="#ffcf4d"/>
    <path d="M150 150 q22 6 30 -6" stroke="#ffd166" stroke-width="6" fill="none" stroke-linecap="round"/>
  </g>
'''

VARIANTS = {
    "1-flag":     FLAG,
    "2-doubloons": COINS,
    "3-map":      MAP,
    "4-rum":      RUM,
    "5-hat":      HAT,
    "6-parrot":   PARROT,
}

for name, acc in VARIANTS.items():
    svg = f'<svg width="512" height="512" viewBox="0 0 512 512" xmlns="http://www.w3.org/2000/svg">{DEFS}{CARD}{acc}{WORDMARK}'
    p = OUT / f"cove-{name}.svg"
    p.write_text(svg)
    subprocess.run(["rsvg-convert", "-w", "512", "-h", "512", str(p),
                    "-o", str(OUT / f"cove-{name}.png")], check=True)
    print("wrote", p.name)
