extends Node
## Records every frame's wall-clock time (ticks between two _process calls), the cell events of the game and the
## video memory, for the performance scenarios. Written as CSV: t_s,frame_ms,phase,cell,event,vram_mb

var rows: Array = []  # [t_s, frame_ms, phase, cell, event, vram_mb]
var phase := "idle"
var cell := ""
var _last_us := 0
var _t0_us := 0
var _pending_events: Array = []
var _vram_mb := 0.0
var _vram_t := 0.0
var loads: Array = []  # [t_s, cell] of cell_loaded


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1000
	_t0_us = Time.get_ticks_usec()
	_last_us = _t0_us


func start(g: Node) -> void:
	if g != null:
		for s in ["cell_loaded", "cell_insert_started", "cell_evicted"]:
			if g.has_signal(s):
				g.connect(s, _on_event.bind(s))


func _on_event(c: Variant, sig: String) -> void:
	var t := (Time.get_ticks_usec() - _t0_us) / 1e6
	var label := "%s %s" % [sig, str(c)]
	_pending_events.append(label)
	if sig == "cell_loaded":
		loads.append([t, str(c)])


static func vram_mb() -> float:
	return Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var ms := (now - _last_us) / 1000.0
	_last_us = now
	var t := (now - _t0_us) / 1e6
	if t - _vram_t >= 0.5:
		_vram_t = t
		_vram_mb = vram_mb()
	rows.append([snappedf(t, 0.0001), snappedf(ms, 0.001), phase, cell, " | ".join(_pending_events), snappedf(_vram_mb, 0.1)])
	_pending_events.clear()


func write_csv(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_line("t_s,frame_ms,phase,cell,event,vram_mb")
	for r in rows:
		f.store_line("%s,%s,%s,%s,%s,%s" % [r[0], r[1], r[2], str(r[3]).replace(",", ";"), str(r[4]).replace(",", ";"), r[5]])
	f.close()
	return true


func stats(phase_name: String, load_window_before_s: float = 1.0, load_window_after_s: float = 0.25) -> Dictionary:
	## avg fps, 1 % low (1000 / 99th percentile frame time) and the worst frame inside cell-load windows
	var ms: Array = []
	var total := 0.0
	var worst_load := 0.0
	var worst_any := 0.0
	for r in rows:
		if r[2] != phase_name:
			continue
		ms.append(r[1])
		total += r[1]
		worst_any = maxf(worst_any, r[1])
		# a row is stamped at the END of its frame: the frame covers [t - ms, t]; it is a load frame when that interval
		# overlaps [load - before, load + after] (the frame that contains the load event counts)
		var f_end: float = r[0]
		var f_start: float = r[0] - r[1] / 1000.0
		for l in loads:
			if f_end >= l[0] - load_window_before_s and f_start <= l[0] + load_window_after_s:
				worst_load = maxf(worst_load, r[1])
				break
	if ms.is_empty():
		return {"frames": 0}
	ms.sort()
	var p99: float = ms[mini(ms.size() - 1, int(ceil(ms.size() * 0.99)) - 1)]
	return {"frames": ms.size(), "seconds": snappedf(total / 1000.0, 0.01), "fps_avg": snappedf(ms.size() / (total / 1000.0), 0.1),
		"fps_1pct_low": snappedf(1000.0 / p99, 0.1), "p99_ms": snappedf(p99, 0.01), "worst_ms": snappedf(worst_any, 0.01),
		"worst_load_ms": snappedf(worst_load, 0.01)}
