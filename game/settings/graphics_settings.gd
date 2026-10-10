extends Node
## Autoload `GraphicsSettings` (BRIEF-0.3 "Optimalizace", sheet rows graphics.*): presets low / medium / high and the
## manual options, saved in graphics.json next to settings.json (or in --user-dir), applied immediately.
##
## Applied here globally: fps limit (Engine.max_fps), VSync, render scale + FSR and LOD bias on the root viewport,
## shadow atlas / soft filter quality. Things that live in other code are applied through hooks that hand their
## objects to this node once (each hook line is marked "GRAPHICS HOOK"):
##   attach_environment(env, sun)   - main.gd apply_render_settings: SSAO, SSR, volumetric fog, sun shadow
##                                    on/off, splits and distance
##   track_chunk(mmi, chunk_name)   - cell_builder.make_chunk: scattered vegetation fade distance and density
##
## Command line (this run only, nothing saved): --gfx-preset low|medium|high, --fps-limit <n> (0 = unlimited).

signal changed(key: String)   ## after a setting was changed and applied; "" = everything (load, preset)

const Sheets := preload("res://core/sheets.gd")
const Paths := preload("res://core/paths.gd")
const Log := preload("res://core/log.gd")

const FORMAT := 1
const VEG_GROUP := "gfx_vegetation"
const VEG_CHANNELS := ["trees", "blockbush", "undergrowth", "stealthplants"]
## Manual options (keys of graphics.presets entries + fps_limit, vsync).
const OPTION_KEYS := ["render_scale", "fsr", "shadow_quality", "shadow_distance", "veg_distance", "veg_density",
	"lod_bias", "ssao", "ssr", "volumetric_fog"]

var preset := "high"           ## low / medium / high / custom
var fps_limit := 60            ## Engine.max_fps, 0 = unlimited
var vsync := true
var render_scale := 1.0        ## 0.5 .. 1.0
var fsr := true                ## FSR 1 upscaling when render_scale < 1 (else bilinear)
var shadow_quality := "medium" ## graphics.shadow_quality_order
var shadow_distance := 100.0   ## m
var veg_distance := 1.0        ## x scattered vegetation fade distance
var veg_density := 1.0         ## share of scattered non-tree vegetation drawn
var lod_bias := 1.0            ## mesh_lod_threshold = render.lod_threshold_px / lod_bias
var ssao := false
var ssr := false
var volumetric_fog := false
var auto_info := {}            ## first-start detection: {gpu, vram_mib, type, preset, reason}

var _path := ""
var _save_enabled := true
var _fps_override := -1
var _env: Environment
var _sun: DirectionalLight3D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_path = settings_path()
	# headless runs (tools, tests without a window) cannot classify the GPU: never write their guess into the
	# player's file (only into an explicit --user-dir profile)
	_save_enabled = DisplayServer.get_name() != "headless" or _arg_value("--user-dir") != ""
	var loaded := _load()
	if not loaded:
		auto_info = detect_auto_preset()
		_set_preset_values(str(auto_info.get("preset", "medium")))
		fps_limit = int(Sheets.sys_num("graphics.fps_limit_default", 60))
		vsync = Sheets.sys_bool("graphics.vsync_default", true)
		save()
	_apply_cmdline()
	apply_all()
	_log_startup.call_deferred(loaded)


func _log_startup(loaded: bool) -> void:
	Log.info("graphics: %s %s (file %s), %s" % ["loaded" if loaded else "first start, auto preset", preset, _path,
		describe()])
	if not loaded or not auto_info.is_empty():
		Log.info("graphics: gpu %s" % str(auto_info))


## <--user-dir>/graphics.json, else next to settings.json.
static func settings_path() -> String:
	var file := Sheets.sys_str("graphics.settings_file", "graphics.json")
	var user_dir := _arg_value("--user-dir")
	if user_dir != "":
		return Paths.norm(user_dir).path_join(file)
	return Paths.settings_file().get_base_dir().path_join(file)


static func _arg_value(flag: String) -> String:
	var list := PackedStringArray()
	list.append_array(OS.get_cmdline_args())
	list.append_array(OS.get_cmdline_user_args())
	var i := list.find(flag)
	if i >= 0 and i + 1 < list.size() and not list[i + 1].begins_with("--"):
		return list[i + 1]
	return ""


func _apply_cmdline() -> void:
	var p := _arg_value("--gfx-preset")
	if p != "":
		if presets().has(p):
			_set_preset_values(p)
			_save_enabled = false   # a measurement run must not change the player's file
		else:
			push_warning("graphics: unknown --gfx-preset %s" % p)
	var f := _arg_value("--fps-limit")
	if f != "":
		_fps_override = maxi(int(f), 0)
		fps_limit = _fps_override
		_save_enabled = false


# ------------------------------------------------------------------ sheet data

static func presets() -> Dictionary:
	var v: Variant = Sheets.sys("graphics.presets")
	return v if v is Dictionary else {}


static func preset_order() -> Array:
	var v: Variant = Sheets.sys("graphics.preset_order")
	return v if v is Array else ["low", "medium", "high"]


static func shadow_steps() -> Dictionary:
	var v: Variant = Sheets.sys("graphics.shadow_quality_steps")
	return v if v is Dictionary else {}


static func list_row(id: String, fallback: Array) -> Array:
	var v: Variant = Sheets.sys(id)
	return v if v is Array and not (v as Array).is_empty() else fallback


# ------------------------------------------------------------------ getters / setters

func get_value(key: String) -> Variant:
	return get(key)


## Sets one manual option (key in OPTION_KEYS, "fps_limit" or "vsync"), applies it, saves and emits `changed`.
## The preset becomes "custom" when the options no longer equal a preset.
func set_value(key: String, value: Variant) -> void:
	if not (key in OPTION_KEYS or key == "fps_limit" or key == "vsync"):
		push_warning("graphics: unknown setting %s" % key)
		return
	match typeof(get(key)):
		TYPE_BOOL:
			set(key, bool(value))
		TYPE_INT:
			set(key, int(value))
		TYPE_FLOAT:
			set(key, float(value))
		_:
			set(key, str(value))
	_clamp()
	if key == "fps_limit":
		_fps_override = -1
	preset = _matching_preset()
	_apply_key(key)
	save()
	Log.info("graphics: %s = %s (preset %s)" % [key, str(get(key)), preset])
	changed.emit(key)


## Applies a preset (low / medium / high): every manual option except fps limit and VSync.
func set_preset(name: String) -> void:
	if not presets().has(name):
		push_warning("graphics: unknown preset %s" % name)
		return
	_set_preset_values(name)
	apply_all()
	save()
	Log.info("graphics: preset %s (%s)" % [name, describe()])
	changed.emit("")


func _set_preset_values(name: String) -> void:
	var p: Dictionary = presets().get(name, {})
	for k in OPTION_KEYS:
		if p.has(k):
			var cur: Variant = get(k)
			match typeof(cur):
				TYPE_BOOL:
					set(k, bool(p[k]))
				TYPE_FLOAT:
					set(k, float(p[k]))
				_:
					set(k, str(p[k]))
	_clamp()
	preset = name


func _matching_preset() -> String:
	var all := presets()
	for name in preset_order():
		var p: Dictionary = all.get(name, {})
		var same := not p.is_empty()
		for k in OPTION_KEYS:
			if not p.has(k):
				continue
			var a: Variant = get(k)
			var b: Variant = p[k]
			if typeof(a) == TYPE_FLOAT:
				same = same and is_equal_approx(float(a), float(b))
			elif typeof(a) == TYPE_BOOL:
				same = same and bool(a) == bool(b)
			else:
				same = same and str(a) == str(b)
		if same:
			return str(name)
	return "custom"


func _clamp() -> void:
	var r := list_row("graphics.render_scale_range", [0.5, 1.0, 0.05])
	render_scale = clampf(render_scale, float(r[0]), float(r[1]))
	if not shadow_steps().has(shadow_quality):
		shadow_quality = "medium"
	shadow_distance = clampf(shadow_distance, 10.0, 1000.0)
	veg_distance = clampf(veg_distance, 0.1, 4.0)
	veg_density = clampf(veg_density, 0.0, 1.0)
	lod_bias = clampf(lod_bias, 0.1, 8.0)
	fps_limit = maxi(fps_limit, 0)


func describe() -> String:
	return "fps %s, vsync %s, scale %.2f%s, shadows %s %.0f m, vegetation x%.2f distance x%.2f density, lod bias %.2f, ssao %s, ssr %s, volumetric fog %s" % [
		"unlimited" if fps_limit == 0 else str(fps_limit), vsync, render_scale, " fsr" if fsr else "", shadow_quality,
		shadow_distance, veg_distance, veg_density, lod_bias, ssao, ssr, volumetric_fog]


# ------------------------------------------------------------------ persistence

func _load() -> bool:
	if not FileAccess.file_exists(_path):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("graphics: %s is not valid JSON, auto preset again" % _path)
		return false
	var d: Dictionary = parsed
	var name := str(d.get("preset", "custom"))
	if presets().has(name):
		_set_preset_values(name)
	for k in OPTION_KEYS + ["fps_limit", "vsync"]:
		if d.has(k) and d[k] != null:
			match typeof(get(k)):
				TYPE_BOOL:
					set(k, bool(d[k]))
				TYPE_INT:
					set(k, int(d[k]))
				TYPE_FLOAT:
					set(k, float(d[k]))
				_:
					set(k, str(d[k]))
	_clamp()
	preset = _matching_preset()
	if d.get("auto") is Dictionary:
		auto_info = d["auto"]
	return true


func save() -> void:
	if not _save_enabled or _path == "":
		return
	var d := {"format": FORMAT, "preset": preset, "fps_limit": fps_limit, "vsync": vsync, "auto": auto_info}
	for k in OPTION_KEYS:
		d[k] = get(k)
	DirAccess.make_dir_recursive_absolute(_path.get_base_dir())
	var tmp := _path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("graphics: cannot write %s (%s)" % [tmp, error_string(FileAccess.get_open_error())])
		return
	f.store_string(JSON.stringify(d, "  "))
	f.close()
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(_path)
	DirAccess.rename_absolute(tmp, _path)


# ------------------------------------------------------------------ apply

func apply_all() -> void:
	for k in ["fps_limit", "vsync", "render_scale", "lod_bias", "shadow_quality", "environment", "vegetation"]:
		_apply_key(k)


func _apply_key(key: String) -> void:
	match key:
		"fps_limit":
			# headless runs (tools, headless tests) draw nothing: they keep the engine's unlimited loop
			if DisplayServer.get_name() != "headless" or _fps_override >= 0:
				Engine.max_fps = fps_limit
		"vsync":
			if DisplayServer.get_name() != "headless":
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
		"render_scale", "fsr":
			var vp := get_tree().root
			vp.scaling_3d_scale = render_scale
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if fsr and render_scale < 0.999 else Viewport.SCALING_3D_MODE_BILINEAR
			vp.fsr_sharpness = Sheets.sys_num("graphics.fsr_sharpness", 0.2)
		"lod_bias":
			get_tree().root.mesh_lod_threshold = Sheets.sys_num("render.lod_threshold_px", 12.0) / maxf(lod_bias, 0.01)
		"shadow_quality", "shadow_distance":
			var s: Dictionary = shadow_steps().get(shadow_quality, {})
			RenderingServer.directional_shadow_atlas_set_size(int(s.get("atlas_px", 2048)), true)
			RenderingServer.directional_soft_shadow_filter_set_quality(int(s.get("soft", 2)))
			RenderingServer.positional_soft_shadow_filter_set_quality(int(s.get("soft", 2)))
			_apply_sun()
		"ssao", "ssr", "volumetric_fog", "environment":
			_apply_environment()
		"veg_distance", "veg_density", "vegetation":
			for n in get_tree().get_nodes_in_group(VEG_GROUP):
				_apply_chunk(n as MultiMeshInstance3D)


func _apply_sun() -> void:
	if _sun == null or not is_instance_valid(_sun):
		return
	var s: Dictionary = shadow_steps().get(shadow_quality, {})
	_sun.shadow_enabled = bool(s.get("enabled", true))
	match int(s.get("splits", 2)):
		1:
			_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		4:
			_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		_:
			_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	_sun.directional_shadow_max_distance = shadow_distance


func _apply_environment() -> void:
	if _env != null:
		_env.ssao_enabled = ssao
		if ssao:
			RenderingServer.environment_set_ssao_quality(int(Sheets.sys_num("graphics.ssao_quality", 1)), true, 0.5, 2, 50.0, 300.0)
		_env.ssr_enabled = ssr
		_env.ssr_max_steps = int(Sheets.sys_num("graphics.ssr_max_steps", 32))
		_env.volumetric_fog_enabled = volumetric_fog
	_apply_sun()


# ------------------------------------------------------------------ hooks (called from other owners' code)

## GRAPHICS HOOK target (main.gd apply_render_settings, after the render.* rows were applied): keeps the scene's
## Environment and sun and overrides what the graphics settings own (SSAO, SSR, volumetric fog, sun shadows, LOD).
func attach_environment(env: Environment, sun: DirectionalLight3D) -> void:
	_env = env
	_sun = sun
	_apply_environment()
	_apply_key("lod_bias")


## GRAPHICS HOOK target (cell_builder.make_chunk): scattered vegetation chunks ("<channel>:<mesh>") follow
## veg_distance (fade end) and veg_density (non-tree channels: visible instance count).
func track_chunk(mmi: MultiMeshInstance3D, chunk_name: String) -> void:
	if mmi == null:
		return
	var ch := chunk_name.get_slice(":", 0)
	if not chunk_name.contains(":") or not ch in VEG_CHANNELS:
		return
	mmi.set_meta("gfx_vis_end", mmi.visibility_range_end)
	mmi.set_meta("gfx_count", mmi.multimesh.instance_count if mmi.multimesh else 0)
	mmi.set_meta("gfx_thin", ch != "trees")
	mmi.add_to_group(VEG_GROUP)
	_apply_chunk(mmi)


func _apply_chunk(mmi: MultiMeshInstance3D) -> void:
	if mmi == null or not is_instance_valid(mmi):
		return
	var end := float(mmi.get_meta("gfx_vis_end", 0.0))
	if end > 0.0:
		mmi.visibility_range_end = end * veg_distance
	if bool(mmi.get_meta("gfx_thin", false)) and mmi.multimesh:
		var n := int(mmi.get_meta("gfx_count", 0))
		mmi.multimesh.visible_instance_count = -1 if veg_density >= 0.999 else int(round(n * veg_density))


# ------------------------------------------------------------------ first start: GPU classification

## Classifies the GPU from the adapter name/type and its VRAM (Windows registry HardwareInformation.qwMemorySize of
## the display adapter with the same name; Godot 4.7.2 exposes no VRAM capacity) -> {gpu, vram_mib, type, preset, reason}.
static func detect_auto_preset() -> Dictionary:
	var rules: Dictionary = {}
	var rv: Variant = Sheets.sys("graphics.auto_preset")
	if rv is Dictionary:
		rules = rv
	var fallback := Sheets.sys_str("graphics.fallback_preset", "medium")
	var name := RenderingServer.get_video_adapter_name()
	var type := RenderingServer.get_video_adapter_type()
	var out := {"gpu": name, "vendor": RenderingServer.get_video_adapter_vendor(), "type": type, "vram_mib": 0,
		"preset": fallback, "reason": "unknown GPU"}
	if name == "" or DisplayServer.get_name() == "headless":
		out["reason"] = "no GPU adapter (headless)"
		return out
	var vram := vram_mib_of(name)
	out["vram_mib"] = vram
	if type == RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU:
		out["preset"] = str(rules.get("integrated", "low"))
		out["reason"] = "integrated GPU"
		return out
	if type == RenderingDevice.DEVICE_TYPE_CPU or type == RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU:
		out["preset"] = str(rules.get("cpu_or_virtual", "low"))
		out["reason"] = "CPU / virtual GPU"
		return out
	for pat in rules.get("low_name_patterns", []):
		if name.containsn(str(pat)):
			out["preset"] = "low"
			out["reason"] = "name matches %s" % pat
			return out
	for pat in rules.get("high_name_patterns", []):
		if name.containsn(str(pat)):
			out["preset"] = "high"
			out["reason"] = "name matches %s" % pat
			return out
	if vram <= 0:
		out["reason"] = "VRAM unknown"
		return out
	if vram < int(rules.get("vram_low_below_mib", 4096)):
		out["preset"] = "low"
	elif vram >= int(rules.get("vram_high_from_mib", 7168)):
		out["preset"] = "high"
	else:
		out["preset"] = "medium"
	out["reason"] = "VRAM %d MiB" % vram
	return out


## VRAM in MiB of the display adapter called `adapter` (0 = unknown). Windows only: two non-interactive `reg query`
## calls under the display adapter class key.
static func vram_mib_of(adapter: String) -> int:
	if OS.get_name() != "Windows":
		return 0
	var key := "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}"
	var names := _reg_values(key, "DriverDesc")
	var sizes := _reg_values(key, "HardwareInformation.qwMemorySize")
	var best := 0
	for sub in sizes:
		var mib := (str(sizes[sub]).hex_to_int() >> 20) if str(sizes[sub]).begins_with("0x") else 0
		if str(names.get(sub, "")).strip_edges() == adapter.strip_edges():
			return mib
		best = maxi(best, mib)
	return best if names.size() <= 1 else 0


## `reg query <key> /s /v <value>` -> {subkey: data string}.
static func _reg_values(key: String, value: String) -> Dictionary:
	var output := []
	var code := OS.execute("reg", ["query", key, "/s", "/v", value], output, true)
	var out := {}
	if code != 0 or output.is_empty():
		return out
	var sub := ""
	for line in str(output[0]).split("\n"):
		var t := line.strip_edges()
		if t.begins_with("HKEY_"):
			sub = t.get_file()
		elif t.begins_with(value + " ") and sub != "":
			var parts := t.split("    ", false)
			if parts.size() >= 3:
				out[sub] = parts[2].strip_edges()
	return out
