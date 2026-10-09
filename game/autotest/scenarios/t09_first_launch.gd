extends "res://autotest/lib/scenario.gd"
## t09 First launch does not convert the whole world. Runs in a child process with an empty --cache-dir:
## at world_ready (playable) only the start cell is on disk; the bootstrap ring follows in the background and the
## cells on disk stay a small area around the start (streaming request ring), never the world. Records
## bootstrap_seconds and cache size for the release summary.

const Proc := preload("res://autotest/lib/proc.gd")
const Oracle := preload("res://autotest/lib/oracle.gd")


func _init() -> void:
	timeout_s = 5300.0


func _run(ctx):
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["bootstrap_seconds", "cells_converted"], ["cache_bytes", "cells_on_disk"])):
		return false
	var o = ctx.oracle
	var cache: String = o.cache_dir
	data.cache_dir = cache
	var cells0: Array = Proc.cell_dirs(cache)
	check("setup: cache folder had no cells when the runner started", cells0.is_empty(), str(cells0))

	var ready: bool = await ctx.need_world(4500.0)
	if not check("world_ready (playable) within 4500 s", ready):
		return false
	var at_ready_cells_api := _cells(await ctx.call_api(g, "cells_on_disk"))
	var at_ready_cells_disk: Array = Proc.cell_dirs(cache)
	var bytes_api := int(await ctx.call_api(g, "cache_bytes"))
	var bytes_disk: int = await ctx.in_thread(Proc.dir_bytes.bind(cache))
	o.reload()  # the resolved tables exist now
	var idx: Dictionary = o.index_json()
	var start: Vector2i = ctx.v2i(idx.get("start_cell", o.system("streaming.start_cell")))
	var total := (idx.get("cells", []) as Array).size()
	data.bootstrap_seconds = g.get("bootstrap_seconds")
	data.world_ready_after_engine_start_s = snappedf(ctx.world_ready_t, 0.1)
	data.at_world_ready = {"cells_api": _fmt(at_ready_cells_api), "cells_disk": _fmt(at_ready_cells_disk), "cache_bytes_api": bytes_api, "cache_bytes_disk": bytes_disk, "cache_mib": snappedf(bytes_disk / 1048576.0, 0.1)}
	data.start_cell = _fmt([start])[0]
	data.world_cells = total
	check("Game.bootstrap_seconds > 0", float(g.get("bootstrap_seconds")) > 0.0, str(g.get("bootstrap_seconds")))
	check("at world_ready the cells on disk are only the start cell %s" % str(start), at_ready_cells_disk == [start], _fmt(at_ready_cells_disk))
	check("cells_on_disk() == cell folders in the cache at world_ready", _same(at_ready_cells_api, at_ready_cells_disk), "%s vs %s" % [_fmt(at_ready_cells_api), _fmt(at_ready_cells_disk)])

	# bootstrap ring (3x3) continues in the background
	var br: int = o.i(o.system("streaming.bootstrap_ring"))
	var rr: int = o.i(o.system("streaming.request_ring"))
	var ring := []
	var listed: Array = (idx.get("cells", []) as Array).map(func(c): return ctx.v2i(c))
	for dy in range(-br, br + 1):
		for dx in range(-br, br + 1):
			var c: Vector2i = start + Vector2i(dx, dy)
			if listed.is_empty() or listed.has(c):
				ring.append(c)
	var t_ring := Time.get_ticks_msec()
	var done: bool = await ctx.wait_until(func(): return ring.all(func(c): return Proc.cell_dirs(cache).has(c)), 3600.0)
	var after: Array = Proc.cell_dirs(cache)
	var after_bytes: int = await ctx.in_thread(Proc.dir_bytes.bind(cache))
	data.after_bootstrap = {"ring_seconds_after_ready": snappedf((Time.get_ticks_msec() - t_ring) / 1000.0, 0.1), "cells_disk": _fmt(after), "cache_bytes_disk": after_bytes, "cache_mib": snappedf(after_bytes / 1048576.0, 0.1), "cells_converted": g.get("cells_converted")}
	check("bootstrap ring (%d cells around the start) converted after world_ready" % ring.size(), done, "%d/%d on disk" % [ring.filter(func(c): return after.has(c)).size(), ring.size()])
	var outside := after.filter(func(c): return ctx.chebyshev(c, start) > maxi(br, rr))
	var limit := (2 * maxi(br, rr) + 1) * (2 * maxi(br, rr) + 1)
	check("cells on disk stay around the start (<= %d, within ring %d; world has %d)" % [limit, maxi(br, rr), total], outside.is_empty() and after.size() <= limit, "%d cells, %d outside" % [after.size(), outside.size()])

	# weapons and machines in the cache
	var w: Variant = Oracle.read_json(cache.path_join("cs2/weapons.json"))
	var missing_w := []
	for id in WeaponsSheet.ROWS:
		if not (w is Dictionary and w.get(id) is Dictionary):
			missing_w.append(id)
	check("%d weapons in cs2/weapons.json" % WeaponsSheet.ROWS.size(), missing_w.is_empty(), "missing %s" % str(missing_w))
	var missing_m := []
	for id in MachinesSheet.ROWS:
		if not FileAccess.file_exists(cache.path_join("hzd/machines/%s/model.glb" % id)):
			missing_m.append(id)
	check("%d machines (hzd/machines/<id>/model.glb)" % MachinesSheet.ROWS.size(), missing_m.is_empty(), "missing %s" % str(missing_m))
	return true


static func _cells(v: Variant) -> Array:
	var out := []
	if v is Array:
		for c in v:
			out.append(Vector2i(int(c.x), int(c.y)) if (c is Vector2i or c is Vector2) else Vector2i(int(c[0]), int(c[1])))
	return out


static func _same(a: Array, b: Array) -> bool:
	return a.size() == b.size() and a.all(func(c): return b.has(c))


static func _fmt(cells: Array) -> Array:
	return cells.map(func(c): return "%d_%d" % [c.x, c.y])
