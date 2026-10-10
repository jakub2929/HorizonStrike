extends "res://autotest/lib/framerec.gd"
## FrameRec plus GPU and CPU time per frame (systems perf.gpu_time_rule) and RAM / VRAM samples (perf.ram_rule), for
## t25 and t27. GPU time = measured GPU render time of the root viewport and every SubViewport (the first-person
## weapon is drawn by one); CPU time = process + physics + render setup + viewport CPU render times.
## CSV: t_s, frame_ms, phase, cell, event, vram_mb, gpu_ms, cpu_ms, process_ms, physics_ms, render_cpu_ms. Memory: start_mem_sampler(ctx) -> mem rows.

const Proc := preload("res://autotest/lib/proc.gd")

var gpu: Array = []   # per row of `rows`
var cpu: Array = []
var cpu_parts: Array = []   # [process_ms, physics_ms, render_cpu_ms] per row (diagnosis of cpu_ms)
var mem: Array = []   # [t_s, phase, game_mb, converter_mb, vram_mb]
var sampling := false
var _vps: Array = []
var _vp_scan := -1.0


func _ready() -> void:
	super()
	_scan_viewports()


func _scan_viewports() -> void:
	_vps.clear()
	var nodes: Array = [get_tree().root]
	nodes.append_array(get_tree().root.find_children("*", "SubViewport", true, false))
	for v in nodes:
		var rid: RID = (v as Viewport).get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(rid, true)
		_vps.append(rid)


func _process(delta: float) -> void:
	super(delta)
	var t: float = rows[rows.size() - 1][0] if not rows.is_empty() else 0.0
	if t - _vp_scan >= 5.0:
		_vp_scan = t
		_scan_viewports()
	var g := 0.0
	var rc := RenderingServer.get_frame_setup_time_cpu()
	for rid in _vps:
		g += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		rc += RenderingServer.viewport_get_measured_render_time_cpu(rid)
	var pr := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var ph := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	gpu.append(snappedf(g, 0.001))
	cpu.append(snappedf(pr + ph + rc, 0.001))
	cpu_parts.append([snappedf(pr, 0.001), snappedf(ph, 0.001), snappedf(rc, 0.001)])


func write_csv(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_line("t_s,frame_ms,phase,cell,event,vram_mb,gpu_ms,cpu_ms,process_ms,physics_ms,render_cpu_ms")
	for i in rows.size():
		var r: Array = rows[i]
		var cp: Array = cpu_parts[i] if i < cpu_parts.size() else ["", "", ""]
		f.store_line("%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s" % [r[0], r[1], r[2], str(r[3]).replace(",", ";"), str(r[4]).replace(",", ";"), r[5],
			gpu[i] if i < gpu.size() else "", cpu[i] if i < cpu.size() else "", cp[0], cp[1], cp[2]])
	f.close()
	return true


func write_mem_csv(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_line("t_s,phase,game_mb,converter_mb,vram_mb")
	for m in mem:
		f.store_line("%s,%s,%s,%s,%s" % m)
	f.close()
	return true


func gpu_stats(phase_name: String) -> Dictionary:
	## GPU / CPU ms per frame (avg, p99) and GPU load = GPU busy ms per wall-clock second over the phase
	var gs: Array = []
	var cs: Array = []
	var parts := [0.0, 0.0, 0.0]
	var wall_ms := 0.0
	for i in rows.size():
		if rows[i][2] != phase_name or i >= gpu.size():
			continue
		gs.append(gpu[i])
		cs.append(cpu[i])
		for k in 3:
			parts[k] += float(cpu_parts[i][k])
		wall_ms += float(rows[i][1])
	if gs.is_empty():
		return {"frames": 0}
	var gsum: float = gs.reduce(func(a, b): return a + b, 0.0)
	var csum: float = cs.reduce(func(a, b): return a + b, 0.0)
	gs.sort()
	cs.sort()
	var k := mini(gs.size() - 1, int(ceil(gs.size() * 0.99)) - 1)
	return {"gpu_ms_avg": snappedf(gsum / gs.size(), 0.01), "gpu_ms_p99": snappedf(gs[k], 0.01),
		"cpu_ms_avg": snappedf(csum / cs.size(), 0.01), "cpu_ms_p99": snappedf(cs[k], 0.01),
		"gpu_busy_ms_per_s": snappedf(gsum / maxf(wall_ms / 1000.0, 0.001), 0.1), "frame_ms_avg": snappedf(wall_ms / gs.size(), 0.01),
		"process_ms_avg": snappedf(parts[0] / gs.size(), 0.01), "physics_ms_avg": snappedf(parts[1] / gs.size(), 0.01),
		"render_cpu_ms_avg": snappedf(parts[2] / gs.size(), 0.01)}


func mem_stats(phases: Array = []) -> Dictionary:
	## peak and last sample per column over the samples taken in `phases` (all when empty)
	var out := {"samples": 0}
	for key in [["game_mb", 2], ["converter_mb", 3], ["vram_mb", 4]]:
		var vals: Array = []
		for m in mem:
			if (phases.is_empty() or phases.has(m[1])) and float(m[key[1]]) >= 0.0:
				vals.append(float(m[key[1]]))
		if vals.is_empty():
			continue
		out.samples = vals.size()
		out[key[0] + "_peak"] = snappedf(vals.max(), 0.1)
		out[key[0] + "_end"] = snappedf(vals[vals.size() - 1], 0.1)
	return out


func start_mem_sampler(ctx, every_s: float) -> void:
	## runs until `sampling` is cleared: game + converter working set (tasklist on a worker thread) and VRAM
	sampling = true
	while sampling and is_inside_tree():
		var conv := int(ctx.game.get("converter_pid")) if ctx.game != null and "converter_pid" in ctx.game else 0
		var ws: Dictionary = await working_sets(ctx, [OS.get_process_id(), conv])
		var t: float = rows[rows.size() - 1][0] if not rows.is_empty() else 0.0
		mem.append([snappedf(t, 0.01), phase, ws.get(OS.get_process_id(), -1.0), ws.get(conv, -1.0) if conv > 0 else -1.0, snappedf(vram_mb(), 0.1)])
		await ctx.wait(every_s)


static func working_sets(ctx, pids: Array) -> Dictionary:
	## pid -> working set MiB (tasklist "Mem Usage" column, locale-independent digits); missing pids are absent
	var r: Dictionary = await ctx.run_cmd(Proc.system32("tasklist.exe"), PackedStringArray(["/FO", "CSV", "/NH"]))
	var out := {}
	for raw in str(r.get("out", "")).split("\n"):
		var f := raw.strip_edges().split("\",\"")
		if f.size() < 5:
			continue
		var pid := int(f[1].trim_prefix("\"").trim_suffix("\""))
		if not pids.has(pid) or pid <= 0:
			continue
		var digits := ""
		for ch in f[4]:
			if ch >= "0" and ch <= "9":
				digits += ch
		if digits != "":
			out[pid] = snappedf(int(digits) / 1024.0, 0.1)
	return out
