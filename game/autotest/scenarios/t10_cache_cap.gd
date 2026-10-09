extends "res://autotest/lib/scenario.gd"
## t10 Cache never exceeds the cap (inside the t09 child, fresh cache). Cap = bytes now + cache.reserve_mib + 300 MiB;
## teleport one cell east 5 times (waiting for cell_loaded), then back to the start. The cache size is sampled both
## through Game.cache_bytes() and independently from the folder on disk. Restores the previous cap at the end.

const Proc := preload("res://autotest/lib/proc.gd")

const STEPS := 5
const EXTRA_MIB := 300


func _init() -> void:
	timeout_s = 5300.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(4500.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["cache_cap_bytes", "player"], ["cache_bytes", "cells_on_disk", "teleport"], ["cell_evicted", "cell_loaded"]) + ctx.missing_api(p, ["invulnerable"])):
		return false
	var o = ctx.oracle
	var cache: String = o.cache_dir
	var idx: Dictionary = o.index_json()
	var start: Vector2i = ctx.v2i(idx.get("start_cell", o.system("streaming.start_cell")))
	var cell_size := float(idx.get("cell_size", o.system("streaming.cell_size_m")))
	var load_ring: int = o.i(o.system("streaming.load_ring"))
	var cap0 := int(g.get("cache_cap_bytes"))
	var bytes0 := int(await ctx.call_api(g, "cache_bytes"))
	var cap: int = bytes0 + int(o.f(o.system("cache.reserve_mib")) * ctx.MIB) + EXTRA_MIB * ctx.MIB
	g.set("cache_cap_bytes", cap)
	data.cap = {"previous": cap0, "bytes_at_start": bytes0, "cap": cap, "cap_mib": snappedf(cap / 1048576.0, 0.1)}

	# samplers: Game.cache_bytes() every 0.5 s, the folder on disk on a worker thread
	var samples := {"game": [], "disk": [], "stop": false}
	var timer := Timer.new()
	timer.wait_time = 0.5
	timer.process_mode = Node.PROCESS_MODE_ALWAYS
	timer.timeout.connect(func(): samples.game.append(int(g.call("cache_bytes"))))
	ctx.runner.add_child(timer)
	timer.start()
	var disk_walk := func() -> Array:
		var out := []
		while not samples.stop:
			out.append(Proc.dir_bytes(cache))
			OS.delay_msec(1000)
		return out
	var disk_thread := Thread.new()
	disk_thread.start(disk_walk)

	var cur := {"cell": start}
	var evictions := []
	var on_evict := func(c: Variant) -> void:
		var cell: Vector2i = ctx.v2i(c)
		var pc: Vector2i = ctx.v2i(g.call("cell_of", ctx.player_pos())) if g.has_method("cell_of") else cur.cell
		evictions.append({"cell": "%d_%d" % [cell.x, cell.y], "player_cell": "%d_%d" % [pc.x, pc.y], "ring": ctx.chebyshev(cell, pc), "t": Time.get_ticks_msec()})
	g.connect("cell_evicted", on_evict)
	var loaded_rec = ctx.record(g, "cell_loaded")
	p.set("invulnerable", true)
	var p0: Vector3 = ctx.player_pos()
	var steps := []
	for k in range(1, STEPS + 1):
		var target := p0 + Vector3(cell_size * k, 30.0, 0.0)
		var want := start + Vector2i(k, 0)
		cur.cell = want
		var t0 := Time.get_ticks_msec()
		await ctx.call_api(g, "teleport", [target])
		var ok: bool = await ctx.wait_until(func(): return loaded_rec.events.any(func(e): return ctx.v2i(e.args[0]) == want and e.t * 1000.0 >= t0 - loaded_rec.t0), 900.0)
		await ctx.wait(3.0)
		steps.append({"cell": "%d_%d" % [want.x, want.y], "loaded": ok, "seconds": snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1), "evictions_so_far": evictions.size()})
		ctx.note("t10 step %d: cell %s loaded=%s, %d evictions, cache %s MiB" % [k, str(want), str(ok), evictions.size(), str(snappedf(int(g.call("cache_bytes")) / 1048576.0, 0.1))])
	# back to the start: evicted cells near the start must come back
	cur.cell = start
	var back_t0 := Time.get_ticks_msec()
	await ctx.call_api(g, "teleport", [p0 + Vector3(0, 30.0, 0)])
	var revisit := []
	for e in evictions:
		var parts: PackedStringArray = str(e.cell).split("_")
		var c := Vector2i(int(parts[0]), int(parts[1]))
		if ctx.chebyshev(c, start) <= load_ring and not revisit.has(c):
			revisit.append(c)
	var back: bool = await ctx.wait_until(func(): return revisit.all(func(c): return Proc.cell_dirs(cache).has(c)), 900.0)
	await ctx.wait(2.0)

	samples.stop = true
	timer.stop()
	timer.queue_free()
	var disk: Array = disk_thread.wait_to_finish()
	g.disconnect("cell_evicted", on_evict)
	g.set("cache_cap_bytes", cap0)
	p.set("invulnerable", false)

	var max_game: int = samples.game.max() if not samples.game.is_empty() else -1
	var max_disk: int = disk.max() if not disk.is_empty() else -1
	data.steps = steps
	data.samples = {"game_n": samples.game.size(), "game_max": max_game, "disk_n": disk.size(), "disk_max": max_disk, "game_max_mib": snappedf(max_game / 1048576.0, 0.1), "disk_max_mib": snappedf(max_disk / 1048576.0, 0.1)}
	data.evictions = evictions.slice(0, 40)
	data.revisit = revisit.map(func(c): return "%d_%d" % [c.x, c.y])
	data.back_seconds = snappedf((Time.get_ticks_msec() - back_t0) / 1000.0, 0.1)
	check("every step's target cell loaded", steps.all(func(s): return s.loaded), str(steps.map(func(s): return s.loaded)))
	check("max Game.cache_bytes() sample <= cap", max_game >= 0 and max_game <= cap, "%d <= %d" % [max_game, cap])
	check("max size of the cache folder on disk <= cap", max_disk >= 0 and max_disk <= cap, "%d <= %d" % [max_disk, cap])
	check(">= 1 cell evicted (cell_evicted)", not evictions.is_empty(), "%d" % evictions.size())
	var prot := evictions.filter(func(e): return e.ring <= load_ring)
	check("no evicted cell was protected (within load_ring %d of the player)" % load_ring, prot.is_empty(), str(prot.slice(0, 5)))
	check("evicted cells near the start came back when revisited", back, "%d to revisit" % revisit.size())
	if not g.has_method("cell_of"):
		note("Game.cell_of(pos) missing: player cell at eviction time taken from the teleport target")
	return true
