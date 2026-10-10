extends RefCounted
## Per-node _process time of the last frame (slow frame diagnosis, world/cell_profiler.gd): the timed nodes call
## FrameStats.note(name, start_usec) at the end of their _process.

static var ms := {}


static func note(name: String, t0_usec: int) -> void:
	ms[name] = (Time.get_ticks_usec() - t0_usec) / 1000.0


## The `n` largest entries above 1 ms, e.g. "audio 412.0, hud 2.1" ("-" when none).
static func top(n: int = 3) -> String:
	var items: Array = []
	for k in ms:
		if float(ms[k]) >= 1.0:
			items.append([float(ms[k]), str(k)])
	items.sort()
	items.reverse()
	var out := PackedStringArray()
	for i in mini(n, items.size()):
		out.append("%s %.1f" % [items[i][1], items[i][0]])
	return ", ".join(out) if not out.is_empty() else "-"
