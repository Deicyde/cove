// CoveInput -- persistent unix-socket client that streams raw terminal
// bytes to hacked kitty's input socket, avoiding a `kitten` process per event.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

using namespace godot;

class CoveInput : public RefCounted {
	GDCLASS(CoveInput, RefCounted);

	int _fd = -1;

protected:
	static void _bind_methods();

public:
	bool connect_to(const String &path);
	bool is_connected() const;
	// Write raw bytes to a pane: [0][pane_id u64][len u32][data].
	bool send_bytes(int64_t pane_id, const PackedByteArray &data);
	// Resize an OS window (by term/os-window id) to cols x rows: [1][id u64][cols u32][rows u32].
	bool send_resize(int64_t os_window_id, int cols, int rows);
	// Spawn a new terminal (hidden OS window): [2][0].
	bool spawn();
	// Drive kitty's text selection on a pane: [3][pane_id u64][phase u8][x u32][y u32][left u8].
	// phase: 0 start, 1 update (drag), 2 end (copies the selection to the clipboard).
	bool send_mouse(int64_t pane_id, int phase, int x, int y, bool in_left_half);
	void close_conn();

	CoveInput() {}
	~CoveInput() { close_conn(); }
};
