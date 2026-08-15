#include "cove_input.h"

#include <godot_cpp/core/class_db.hpp>

#include <cstring>
#include <cstdint>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/un.h>

using namespace godot;

static long cove_now_ms() {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

void CoveInput::_bind_methods() {
	ClassDB::bind_method(D_METHOD("connect_to", "path"), &CoveInput::connect_to);
	ClassDB::bind_method(D_METHOD("is_connected"), &CoveInput::is_connected);
	ClassDB::bind_method(D_METHOD("send_bytes", "pane_id", "data"), &CoveInput::send_bytes);
	ClassDB::bind_method(D_METHOD("send_resize", "os_window_id", "cols", "rows"), &CoveInput::send_resize);
	ClassDB::bind_method(D_METHOD("spawn"), &CoveInput::spawn);
	ClassDB::bind_method(D_METHOD("send_mouse", "pane_id", "phase", "x", "y", "in_left_half"), &CoveInput::send_mouse);
	ClassDB::bind_method(D_METHOD("close_conn"), &CoveInput::close_conn);
}

// Write all of `buf` without ever blocking the caller indefinitely. The fd is
// non-blocking (see connect_to); on a full send buffer we poll for writability up
// to WRITE_BUDGET_MS total, then give up. Returns false if the write couldn't be
// completed, so the caller drops the connection — a half-written message left in
// the stream would desync kitty's reader, so a clean reconnect is the safe reset.
// This is what stops a wedged kitty from freezing Godot's main thread (the socket
// send runs on it, straight out of _unhandled_input).
static const long WRITE_BUDGET_MS = 100;
static bool write_all(int fd, const unsigned char *buf, size_t n) {
	size_t off = 0;
	long deadline = cove_now_ms() + WRITE_BUDGET_MS;
	while (off < n) {
		ssize_t w = ::write(fd, buf + off, n - off);
		if (w > 0) {
			off += (size_t)w;
			continue;
		}
		if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
			long remain = deadline - cove_now_ms();
			if (remain <= 0) return false;  // peer isn't draining; give up
			struct pollfd pfd = { fd, POLLOUT, 0 };
			int pr = ::poll(&pfd, 1, (int)remain);
			if (pr <= 0) {
				if (pr < 0 && errno == EINTR) continue;
				return false;
			}
			continue;
		}
		if (w < 0 && errno == EINTR) continue;
		return false;  // real error (or peer closed)
	}
	return true;
}

bool CoveInput::connect_to(const String &path) {
	close_conn();
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		return false;
	}
	// Without this a write to a peer that has gone away (kitty-side reader
	// closed the input socket) raises SIGPIPE and kills the whole Godot
	// process. SO_NOSIGPIPE makes such writes fail with EPIPE instead, which
	// write_all() already handles by dropping the connection.
	int on = 1;
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
	// Close-on-exec: a child we spawn (kitten @ ls, cove_find, ...) must NOT
	// inherit this socket. An inherited copy keeps the connection open after we
	// reconnect, and kitty's single-client input reader then stays blocked reading
	// that dead connection forever — it never accepts the live Godot, whose writes
	// back up until write() blocks the main thread. That is the beachball hang.
	fcntl(fd, F_SETFD, FD_CLOEXEC);
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
	// Non-blocking, so a full send buffer can never park Godot's main thread in
	// write(); write_all() polls with a bounded budget and drops the conn instead.
	int fl = fcntl(fd, F_GETFL, 0);
	if (fl != -1) {
		fcntl(fd, F_SETFL, fl | O_NONBLOCK);
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

bool CoveInput::send_mouse(int64_t pane_id, int phase, int x, int y, bool in_left_half) {
	if (_fd < 0 || phase < 0 || phase > 2 || x < 0 || y < 0) {
		return false;
	}
	unsigned char msg[19];
	msg[0] = 3;  // MSG_MOUSE
	uint64_t pane = (uint64_t)pane_id;
	memcpy(msg + 1, &pane, 8);
	msg[9] = (unsigned char)phase;
	uint32_t xx = (uint32_t)x, yy = (uint32_t)y;
	memcpy(msg + 10, &xx, 4);
	memcpy(msg + 14, &yy, 4);
	msg[18] = in_left_half ? 1 : 0;
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
