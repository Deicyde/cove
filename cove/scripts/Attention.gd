# "Needs you" focus queue. A termling that needs you (a Claude hook's
# Stop/Notification, or an agent's `status(needs_you|blocked|done)`) is pinged:
#   - nothing focused  -> focus jumps to it straight away;
#   - something focused -> it joins a FIFO queue instead of interrupting;
#   - when you leave focus (unfocus), focus jumps to the head of the queue;
#   - focus switchers (Cmd+J radial, focus cycling) list queued termlings first.
# Attending a termling (focusing it) or the agent reporting `working` again
# takes it off the queue. Pure bookkeeping: Cove.gd owns focus and the camera.
extends RefCounted
class_name CoveAttention

var queue: Array[int] = []   # term ids, oldest ping first


# A termling needs you. Returns the id to focus right now (nothing is focused),
# or -1 if it was queued (or you're already on it).
func ping(id: int, focused_id: int) -> int:
	if id == focused_id:
		return -1
	if focused_id == -1 and queue.is_empty():
		return id
	if not queue.has(id):
		queue.append(id)
	return -1


# You attended `id` (focused it): it no longer needs you.
func on_focus(id: int) -> void:
	queue.erase(id)


# You left focus. Returns the next termling to jump to, or -1.
func on_leave() -> int:
	return queue.pop_front() if not queue.is_empty() else -1


# The agent in `id` reports it's working again; drop any pending ping.
func resolve(id: int) -> void:
	queue.erase(id)


# The termling went away.
func remove(id: int) -> void:
	queue.erase(id)


func is_queued(id: int) -> bool:
	return queue.has(id)


# Reorder a focus-switcher list so queued termlings come first (oldest ping
# first), the rest keep their order.
func rank(order: Array) -> Array:
	var out: Array = []
	for id in queue:
		if order.has(id):
			out.append(id)
	for id in order:
		if not out.has(id):
			out.append(id)
	return out
