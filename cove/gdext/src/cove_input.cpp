#include "cove_input.h"

#include <godot_cpp/core/class_db.hpp>

#include <cstring>
#include <cstdint>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

using namespace godot;

void CoveInput::_bind_methods() {
	ClassDB::bind_method(D_METHOD("connect_to", "path"), &CoveInput::connect_to);
	ClassDB::bind_method(D_METHOD("is_connected"), &CoveInput::is_connected);
	ClassDB::bind_method(D_METHOD("send_bytes", "pane_id", "data"), &CoveInput::send_bytes);
	ClassDB::bind_method(D_METHOD("send_resize", "os_window_id", "cols", "rows"), &CoveInput::send_resize);
	ClassDB::bind_method(D_METHOD("spawn"), &CoveInput::spawn);
	ClassDB::bind_method(D_METHOD("close_conn"), &CoveInput::close_conn);
}

// Write all of `buf`; drop the connection on error. Returns false on failure.
static bool write_all(int fd, const unsigned char *buf, size_t n) {
	size_t off = 0;
	while (off < n) {
		ssize_t w = ::write(fd, buf + off, n - off);
		if (w <= 0) return false;
		off += (size_t)w;
	}
	return true;
}

bool CoveInput::connect_to(const String &path) {
	close_conn();
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		return false;
	}
	struct sockaddr_un addr;
	memset(&addr, 0, sizeof addr);
	addr.sun_family = AF_UNIX;
	CharString p = path.utf8();
	if ((size_t)p.length() >= sizeof addr.sun_path) {
		::close(fd);
		return false;
	}
	strncpy(addr.sun_path, p.get_data(), sizeof addr.sun_path - 1);
	if (::connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
		::close(fd);
		return false;
	}
	_fd = fd;
	return true;
}

bool CoveInput::is_connected() const {
	return _fd >= 0;
}

bool CoveInput::send_bytes(int64_t pane_id, const PackedByteArray &data) {
	if (_fd < 0) {
		return false;
	}
	int64_t n = data.size();
	if (n <= 0 || n > (1 << 20)) {
		return false;
	}
	unsigned char hdr[13];
	hdr[0] = 0;  // MSG_PTY
	uint64_t pane = (uint64_t)pane_id;
	uint32_t len = (uint32_t)n;
	memcpy(hdr + 1, &pane, 8);
	memcpy(hdr + 9, &len, 4);
	if (!write_all(_fd, hdr, sizeof hdr) || !write_all(_fd, data.ptr(), (size_t)n)) {
		close_conn();
		return false;
	}
	return true;
}

bool CoveInput::send_resize(int64_t os_window_id, int cols, int rows) {
	if (_fd < 0 || cols <= 0 || rows <= 0) {
		return false;
	}
	unsigned char msg[17];
	msg[0] = 1;  // MSG_RESIZE
	uint64_t id = (uint64_t)os_window_id;
	uint32_t c = (uint32_t)cols, r = (uint32_t)rows;
	memcpy(msg + 1, &id, 8);
	memcpy(msg + 9, &c, 4);
	memcpy(msg + 13, &r, 4);
	if (!write_all(_fd, msg, sizeof msg)) {
		close_conn();
		return false;
	}
	return true;
}

bool CoveInput::spawn() {
	if (_fd < 0) {
		return false;
	}
	unsigned char msg[9];
	msg[0] = 2;  // MSG_SPAWN
	uint64_t id = 0;
	memcpy(msg + 1, &id, 8);
	if (!write_all(_fd, msg, sizeof msg)) {
		close_conn();
		return false;
	}
	return true;
}

void CoveInput::close_conn() {
	if (_fd >= 0) {
		::close(_fd);
		_fd = -1;
	}
}
