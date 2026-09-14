# "Needs you" queue. A termling that needs you (a Claude hook's
# Stop/Notification, or an agent's `status(needs_you|blocked|done)`) is pinged:
#   - nothing focused and the camera zoomed out -> focus jumps to it straight away;
#   - otherwise it joins the queue and waits: nothing moves the camera or focus
#     by itself. Cmd+' steps through the notifications (see Cove.gd).
#   - focus switchers (Cmd+J radial, focus cycling) list queued termlings first.
# Attending a termling (focusing it yourself) takes it off the queue; the agent
# going back to work doesn't. Pure bookkeeping: Cove.gd owns focus and the camera.
extends RefCounted
class_name CoveAttention

var queue: Array[int] = []   # term ids, oldest ping first


# A termling needs you. can_steal: nothing has focus and you're looking at the
# board from far out, so taking the camera won't pull you out of anything.
# Returns the id to focus right now, or -1 if it was queued (or you're on it).
func ping(id: int, focused_id: int, can_steal: bool) -> int:
	if id == focused_id:
		return -1
	if focused_id == -1 and can_steal:
		return id
	if not queue.has(id):
		queue.append(id)
	return -1


# You attended `id` (focused it): it no longer needs you.
func on_focus(id: int) -> void:
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
