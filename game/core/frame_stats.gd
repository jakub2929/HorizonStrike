extends RefCounted
## Per-node _process time of the last frame (slow frame diagnosis, world/cell_profiler.gd): the timed nodes call
## FrameStats.note(name, start_usec) at the end of their _process.

static var ms := {}
static var _sum_frame := {}   # name -> process frame of the sums in ms (add())


## Summed over one frame (many callers, e.g. every machine): restarts at 0 in a new process frame.
static func add(name: String, t0_usec: int) -> void:
	var f := Engine.get_process_frames()
	var v := (Time.get_ticks_usec() - t0_usec) / 1000.0
	if int(_sum_frame.get(name, -1)) != f:
		_sum_frame[name] = f
		ms[name] = v
	else:
		ms[name] = float(ms[name]) + v


static func note(name: String, t0_usec: int) -> void:
	ms[name] = (Time.get_ticks_usec() - t0_usec) / 1000.0


## The `n` largest entries above 1 ms (sums from add() only of this or the previous frame), e.g. "audio 412.0, hud 2.1" ("-" when none).
static func top(n: int = 5) -> String:
	var items: Array = []
	var f := Engine.get_process_frames()
	for k in ms:
		# a per-frame sum of an older frame is not this frame's cost
		if _sum_frame.has(k) and int(_sum_frame[k]) < f - 1:
			continue
		if float(ms[k]) >= 1.0:
			items.append([float(ms[k]), str(k)])
	items.sort()
	items.reverse()
	var out := PackedStringArray()
	for i in mini(n, items.size()):
		out.append("%s %.1f" % [items[i][1], items[i][0]])
	return ", ".join(out) if not out.is_empty() else "-"
