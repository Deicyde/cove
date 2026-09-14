---
name: cove
description: Work inside the Cove, the user's board of live terminals ("termlings"). Use when you're running in a Cove termling (COVE=1) and want to tell the user your status, name your own termling, put yourself in a frame, keep your own notes or todo lists on the board, or look up other termlings. Agents never move termlings or change focus; the user arranges the board.
---
# The Cove

The Cove is the user's board of live terminals. Each terminal is a **termling**
that sits on a tldraw-style board next to the user's frames, boxes, text and
arrows. **The user owns the layout and their attention.** You never move
termlings, change focus, or drive the camera. You describe yourself, and the
Cove decides how to show it.

The `cove` MCP server is already registered. Everything acts on your own
termling, identified by `$COVE_SESSION` (its abduco session, which survives
kitty restarts).

## Am I in the Cove?

A shell inside the Cove has `COVE=1` and `COVE_SESSION=cove-<n>`. Call
**`whoami`** to get your termling record (id, session, name, frame, cwd), or an
error if you aren't in one.

## Looking around (read-only)

- **`list_terminals`**: every termling (id, session, name, agent, busy, the frame
  it's in as `container`, cwd, project, title) plus the board's frames
  (`zones`: id, name, rect).
- **`board(mine?)`**: the shapes on the board. `mine=true` returns only yours.
- **`find(query)`**: rank termlings by a natural-language description ("the one
  running the tests"). It returns matches and never changes focus.

## Telling the user how you're doing

- **`status(state, summary?)`**: `needs_you`, `blocked` or `done` puts a "!"
  badge on your termling and queues you for the user's attention. If the user
  isn't focused on anything, focus jumps to you; otherwise you wait in a queue,
  and focus comes to you when they leave their current termling. Call it once;
  don't repeat it. `working` clears it.
- The Stop/Notification hooks already ping when you finish or wait for input.
  Use `status` for something more specific ("blocked: need the API key").

## Describing yourself

- **`rename(name)`**: name your own termling, e.g. `auth-refactor`. Only do it
  when a name helps the user; nothing requires it.
- **`join_frame(frame)`** / **`leave_frame()`**: put your own termling into an
  existing frame (by name or shape id from `list_terminals` `zones`), or take it
  out. Frames often share names like "rectangle", so prefer the id. Only
  yourself: you can't place other termlings.

## Your notes on the board

You can keep your own shapes on the board, placed next to your termling. Only
you (and the user) can change them.

- **`add_note(type, text?, items?, color?)`**: `type` is `note`, `todo` or `text`.
  A `todo` with `items` makes a checklist, which is good for showing your plan.
  Returns the shape id.
- **`update_note(id, ...)`**: replace `text` / `color` / `items`, append
  `add_items`, or `check` / `uncheck` / `remove` an item (by index or text).
- **`link(to, from?, text?)`**: an arrow from one of your shapes (or `me`, your
  termling) to a termling id or shape id.
- **`add_link(url)`**: a bookmark card for a link (title, preview image,
  favicon), next to your termling. For a GitHub PR or issue the card shows its
  live state (open / draft / merged / closed) and +/- lines, so when you open a
  PR, put its link on the board. `board` shows the card's `title` and `github`
  state.
- **`delete_notes(ids)`**: remove shapes you own.

Keep it tidy: update one todo list as you go rather than adding new notes, and
delete your notes when the work is done if they're no longer useful.

## Notes

- Commands carry a request id. If the Cove confirms, you get `confirmed: true`,
  and errors (unknown shape, not yours) come back as tool errors. An older Cove
  answers `confirmed: false`; re-read `board` / `list_terminals` to check.
- No-op if the Cove isn't running: reads return an empty world and self
  actions error with "not inside a Cove termling".
