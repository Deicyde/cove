package main

// Predictive local echo, mosh-style, drawn without touching the screen.
//
// Typed characters are shown immediately at the cursor through kitty's IME
// pre-edit overlay (our kitty's OSC 7766), underlined, and dropped as the
// remote's real echo arrives. The overlay is a display layer only: a wrong
// guess (a password prompt, vim's normal mode) never lands in the screen or
// scrollback, it just disappears. Predictions are only shown after a few have
// been confirmed, and stop after one misses.

import (
	"time"
	"unicode/utf8"
)

const oscPredict = "\x1b]7766;"
const st = "\x1b\\"

// ansiScan tracks whether a byte stream is between escape sequences, so we
// only inject our OSC at a safe point, and yields the printable runes.
type ansiScan struct {
	state int // 0 ground, 1 ESC, 2 CSI, 3 OSC/DCS/APC string, 4 string ESC
	utf   []byte
}

func (a *ansiScan) ground() bool { return a.state == 0 && len(a.utf) == 0 }

// feed advances over b, calling emit for each printable rune in ground state.
func (a *ansiScan) feed(b []byte, emit func(rune)) {
	for _, c := range b {
		switch a.state {
		case 0:
			if len(a.utf) > 0 || c >= 0x80 {
				a.utf = append(a.utf, c)
				if utf8.FullRune(a.utf) {
					r, _ := utf8.DecodeRune(a.utf)
					a.utf = a.utf[:0]
					if emit != nil && r != utf8.RuneError {
						emit(r)
					}
				} else if len(a.utf) >= 4 {
					a.utf = a.utf[:0]
				}
				continue
			}
			switch {
			case c == 0x1b:
				a.state = 1
			case c >= 0x20 && c < 0x7f:
				if emit != nil {
					emit(rune(c))
				}
			}
		case 1:
			switch c {
			case '[':
				a.state = 2
			case ']', 'P', '_', '^', 'X':
				a.state = 3
			default:
				if c >= 0x20 && c <= 0x2f { // intermediate: ESC ( B etc.
					continue
				}
				a.state = 0
			}
		case 2:
			if c >= 0x40 && c <= 0x7e {
				a.state = 0
			} else if c == 0x1b {
				a.state = 1
			}
		case 3:
			if c == 0x07 {
				a.state = 0
			} else if c == 0x1b {
				a.state = 4
			}
		case 4:
			if c == '\\' {
				a.state = 0
			} else {
				a.state = 3
			}
		}
	}
}

type pending struct {
	r rune
	t time.Time
}

type predictor struct {
	enabled   bool // the terminal supports the overlay and prediction isn't off
	always    bool // show even on a fast link
	pend      []pending
	streak    int // consecutive confirmed predictions
	confident bool
	shown     string // overlay currently on screen
	out       ansiScan
	in        ansiScan
	srtt      time.Duration
	status    string // shown when nothing is predicted (e.g. "reconnecting")
}

func (p *predictor) threshold() time.Duration {
	if p.always {
		return 0
	}
	return 20 * time.Millisecond
}

// onInput learns from what the user typed.
func (p *predictor) onInput(b []byte) {
	for i := 0; i < len(b); {
		c := b[i]
		if p.in.state != 0 || c == 0x1b {
			// Escape sequences (arrows, mouse, paste brackets) move the cursor in
			// ways we don't model: stop predicting until the screen catches up.
			p.in.feed(b[i:i+1], nil)
			p.pend = p.pend[:0]
			i++
			continue
		}
		switch {
		case c == 0x7f || c == 0x08:
			if n := len(p.pend); n > 0 {
				p.pend = p.pend[:n-1]
			}
			i++
		case c < 0x20:
			p.pend = p.pend[:0] // enter, tab, ctrl keys
			i++
		default:
			r, sz := utf8.DecodeRune(b[i:])
			if r != utf8.RuneError {
				p.pend = append(p.pend, pending{r, time.Now()})
			}
			i += sz
		}
	}
}

// onOutput checks the remote's output against what we predicted.
func (p *predictor) onOutput(b []byte) {
	p.out.feed(b, func(r rune) {
		if len(p.pend) > 0 && p.pend[0].r == r {
			p.pend = p.pend[1:]
			p.streak++
			if p.streak >= 3 {
				p.confident = true
			}
		}
	})
	p.expire()
}

// expire gives up on predictions the remote hasn't echoed in time.
func (p *predictor) expire() {
	if len(p.pend) == 0 {
		return
	}
	limit := max(300*time.Millisecond, 3*p.srtt)
	if time.Since(p.pend[0].t) > limit {
		p.pend = p.pend[:0]
		p.confident, p.streak = false, 0
	}
}

func (p *predictor) want() string {
	if !p.enabled {
		return ""
	}
	if len(p.pend) > 0 && p.confident && p.srtt >= p.threshold() {
		rs := make([]rune, len(p.pend))
		for i, x := range p.pend {
			rs[i] = x.r
		}
		return string(rs)
	}
	return p.status
}

// wrap returns what to write for a chunk of remote output: the overlay is
// lifted before it and put back (at the new cursor) after it.
func (p *predictor) wrap(out []byte) []byte {
	if !p.enabled {
		return out
	}
	var buf []byte
	if p.shown != "" && p.out.ground() {
		buf = append(buf, oscPredict+st...)
		p.shown = ""
	}
	buf = append(buf, out...)
	p.onOutput(out)
	return append(buf, p.refresh(true)...)
}

// refresh returns the escape to bring the overlay up to date, if it's safe to
// inject one now. force re-sends it even if unchanged (the cursor moved).
func (p *predictor) refresh(force bool) []byte {
	if !p.enabled || !p.out.ground() {
		return nil
	}
	w := p.want()
	if w == p.shown && !(force && w != "") {
		return nil
	}
	p.shown = w
	return []byte(oscPredict + w + st)
}

func (p *predictor) clear() []byte {
	if !p.enabled || p.shown == "" {
		return nil
	}
	p.shown = ""
	return []byte(oscPredict + st)
}
