extends RefCounted
## What a gun shot costs (0.3 t24 diagnosis): main-thread time of the parts of weapons.fire() (part(name, t0_usec))
## and the frames after a shot - wall time, process time, render CPU, GPU time of the viewports and pipeline
## compilations - against the frames without a shot. Logged as one summary line every LOG_EVERY shots and for the
## first FIRST_SHOTS shots one line each. tick() runs once per frame (weapons._process).

const Log := preload("res://core/log.gd")
const LOG_EVERY := 40
const FIRST_SHOTS := 3
const AFTER := 4          # frames after a shot that are counted as "shot frames" (+1 = the shot's own frame)

static var _parts := {}   # name -> [sum_ms, max_ms, n] since the last summary
static var _shot_parts := {}   # name -> ms of the current shot (first shots)
static var _shots := 0
static var _since := -1   # frames since the last shot (-1 = none yet)
static var _last_us := 0
static var _rids: Array[RID] = []
static var _pipe := 0
static var _buckets := {}  # "+k" / "rest" -> [n, sum_ms, max_ms, sum_gpu, max_gpu, sum_proc, sum_rcpu, pipelines]


## Measures the GPU time of these viewports from now on (the main one and the viewmodel's SubViewport).
static func watch(vp: Viewport) -> void:
	if vp == null:
		return
	var rid := vp.get_viewport_rid()
	if _rids.has(rid):
		return
	RenderingServer.viewport_set_measure_render_time(rid, true)
	_rids.append(rid)


static func part(name: String, t0_usec: int) -> void:
	var ms := (Time.get_ticks_usec() - t0_usec) / 1000.0
	var e: Array = _parts.get(name, [0.0, 0.0, 0])
	e[0] = float(e[0]) + ms
	e[1] = maxf(float(e[1]), ms)
	e[2] = int(e[2]) + 1
	_parts[name] = e
	_shot_parts[name] = float(_shot_parts.get(name, 0.0)) + ms


static func shot() -> void:
	_shots += 1
	_since = 0


## Once per frame, before the shot of this frame (weapons._process).
static func tick() -> void:
	var now := Time.get_ticks_usec()
	var dt := (now - _last_us) / 1000.0 if _last_us > 0 else 0.0
	_last_us = now
	if dt <= 0.0:
		return
	var gpu := 0.0
	var rcpu := RenderingServer.get_frame_setup_time_cpu()
	for rid in _rids:
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		rcpu += RenderingServer.viewport_get_measured_render_time_cpu(rid)
	var proc := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var pipe := int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_CANVAS) + Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_MESH)
		+ Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SURFACE) + Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW)
		+ Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SPECIALIZATION))
	var dpipe := pipe - _pipe if _pipe > 0 else 0
	_pipe = pipe
	if _since < 0:
		return
	_since += 1
	var key := "+%d" % _since if _since <= AFTER else "rest"
	var b: Array = _buckets.get(key, [0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0])
	b[0] = int(b[0]) + 1
	b[1] = float(b[1]) + dt
	b[2] = maxf(float(b[2]), dt)
	b[3] = float(b[3]) + gpu
	b[4] = maxf(float(b[4]), gpu)
	b[5] = float(b[5]) + proc
	b[6] = float(b[6]) + rcpu
	b[7] = int(b[7]) + dpipe
	_buckets[key] = b
	if _shots <= FIRST_SHOTS and _since <= AFTER:
		Log.info("shot %d frame %s: %.1f ms (gpu %.1f, process %.1f, render cpu %.1f, pipelines +%d)%s" % [_shots, key, dt, gpu, proc, rcpu, dpipe,
			("; fire() parts: " + _fmt_shot()) if _since == 1 else ""])
	if _since == 1:
		_shot_parts.clear()
	if _since == AFTER and _shots % LOG_EVERY == 0:
		_summary()


static func _fmt_shot() -> String:
	var out := PackedStringArray()
	for k in _shot_parts:
		out.append("%s %.2f" % [k, float(_shot_parts[k])])
	return ", ".join(out)


static func _summary() -> void:
	var ps := PackedStringArray()
	for k in _parts:
		var e: Array = _parts[k]
		ps.append("%s %.2f/%.2f" % [k, float(e[0]) / maxi(int(e[2]), 1), float(e[1])])
	var fs := PackedStringArray()
	for k in ["+1", "+2", "+3", "+4", "rest"]:
		if not _buckets.has(k):
			continue
		var b: Array = _buckets[k]
		var n := maxi(int(b[0]), 1)
		fs.append("%s n%d %.1f/%.1f ms gpu %.1f/%.1f proc %.1f rcpu %.1f pipe %d" % [k, int(b[0]), float(b[1]) / n, float(b[2]), float(b[3]) / n, float(b[4]),
			float(b[5]) / n, float(b[6]) / n, int(b[7])])
	Log.info("shot cost after %d shots: fire() parts avg/max ms: %s" % [_shots, ", ".join(ps)])
	Log.info("shot cost frames avg/max: %s" % " | ".join(fs))
	_parts.clear()
	_buckets.clear()
