extends Node
## Boot flow: args -> log -> settings -> HZD detection (MissingHzdScreen) -> converter (or the in-process mock with
## --mock-data) -> bootstrap with real progress -> world streaming -> player at the start campfire -> world_ready.
## Also: autotest runner hook (--autotest), death + campfire respawn (respawn.*), mouse capture, error screen.

const VERSION := "0.1.1"
const Args := preload("res://core/args.gd")
const Log := preload("res://core/log.gd")
const Paths := preload("res://core/paths.gd")
const Settings := preload("res://core/settings.gd")
const Sheets := preload("res://core/sheets.gd")
const HzdDetect := preload("res://core/hzd_detect.gd")
const InputSetup := preload("res://core/input_setup.gd")
const FsUtil := preload("res://core/fsutil.gd")
const ConverterClient := preload("res://core/converter_client.gd")
const MockConverter := preload("res://core/mock_converter.gd")
const World := preload("res://world/world.gd")
const Player := preload("res://player/player.gd")
const Hud := preload("res://ui/hud.gd")
const BuyWheel := preload("res://ui/buy_wheel.gd")
const LoadingScreen := preload("res://ui/loading_screen.gd")
const Precompile := preload("res://world/precompile.gd")
const MessageScreen := preload("res://ui/message_screen.gd")
const SettingsMenu := preload("res://ui/settings_menu.gd")
const AudioDirector := preload("res://audio/audio_director.gd")

const RUNNER := "res://autotest/runner.gd"

var args: RefCounted
var hzd_dir := ""
var converter: Node
var loading: CanvasLayer
var world: Node3D
var player: CharacterBody3D
var index := {}
var start_cell := Vector2i.ZERO
var _t_start := 0.0
var _bootstrap_id := -1
var _phase := "boot"
var _error_shown := false
var _respawn_left := -1.0
var _death_pos := Vector3.ZERO
var _quitting := false
var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _sun: DirectionalLight3D


func _ready() -> void:
	Game.main = self
	args = Args.from_os()
	Game.args = args
	Log.open(Paths.log_file(), not args.autotest)
	Log.info("Horizon Strike %s (Godot %s) pid %d" % [VERSION, Engine.get_version_info().get("string", "?"), OS.get_process_id()])
	Log.info("args: " + args.describe())
	OS.add_logger(load("res://core/engine_logger.gd").new())
	InputSetup.setup()
	Settings.load_from(Paths.settings_file(), Sheets.sys_num("cache.default_cap_gib", 4.0))
	Game.cache_cap_bytes = int(Settings.get_value("cache_cap_bytes", int(4.0 * Settings.GIB)))
	Game.cache_root = Paths.norm(args.cache_dir) if args.cache_dir != "" else Paths.default_cache(args.mock_data)
	Log.info("cache %s, cap %d bytes" % [Game.cache_root, Game.cache_cap_bytes])
	get_tree().auto_accept_quit = false
	_make_environment()
	# periodic performance line in the log (fps, frame time, video memory) for player reports
	var perf := Timer.new()
	perf.wait_time = 30.0
	perf.autostart = true
	perf.timeout.connect(func() -> void:
		Log.info("perf: %.1f fps, %.1f ms process, vram %.0f MB" % [Engine.get_frames_per_second(),
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0]))
	add_child(perf)
	if args.autotest:
		_start_runner()
	if args.exit_after > 0.0:
		get_tree().create_timer(args.exit_after, true, false, true).timeout.connect(func(): quit_game(0))
	if args.screenshot_at > 0.0:
		get_tree().create_timer(args.screenshot_at, true, false, true).timeout.connect(func(): Game.screenshot(args.screenshot_path))
	if not args.mock_data or args.hzd_given:
		var det := HzdDetect.detect(args.hzd_given, args.hzd_dir)
		if not det["found"]:
			_show_missing_hzd(str(det["reason"]))
			return
		hzd_dir = det["dir"]
		Log.info("HZD found via %s: %s (build %s)" % [det["source"], hzd_dir, det["build"]])
	_start_bootstrap()


func _start_runner() -> void:
	if ResourceLoader.exists(RUNNER):
		var script: Script = load(RUNNER)
		var r: Node = script.new()
		r.name = "AutotestRunner"
		get_tree().root.add_child.call_deferred(r)
		Log.info("autotest runner started (%s)" % ",".join(args.autotest_ids) if not args.autotest_ids.is_empty() else "autotest runner started (all)")
	else:
		Log.warn("autotest requested but %s is missing; continuing without it" % RUNNER)


func _show_missing_hzd(reason: String) -> void:
	Game.hzd_missing = true
	_phase = "missing"
	var s := MessageScreen.make("MissingHzdScreen", "Horizon Zero Dawn not found", Sheets.sys_str("ui.missing_hzd_message"), reason)
	add_child(s)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Log.info("MissingHzdScreen shown (%s)" % reason)


func show_error(message: String) -> void:
	if _error_shown:
		return
	_error_shown = true
	_phase = "error"
	Log.error("error screen: " + message)
	if loading:
		loading.queue_free()
		loading = null
	var s := MessageScreen.make("ErrorScreen", "Something went wrong", message, "Details are in the log: %s" % Log.path())
	add_child(s)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# ------------------------------------------------------------------ bootstrap

func _start_bootstrap() -> void:
	_phase = "bootstrap"
	_t_start = Time.get_ticks_msec() / 1000.0
	loading = LoadingScreen.new()
	add_child(loading)
	DirAccess.make_dir_recursive_absolute(Game.cache_root)
	var sc: Array = Sheets.sys("streaming.start_cell")
	start_cell = Vector2i(int(sc[0]), int(sc[1]))
	if args.mock_data:
		var mc := MockConverter.new()
		mc.name = "MockConverter"
		mc.cell_size = Sheets.sys_num("streaming.cell_size_m", 512.0)
		mc.seed_cache = Paths.norm(args.seed_cache)
		mc.pad_bytes = args.mock_cell_mib * 1048576
		add_child(mc)
		mc.start(Game.cache_root)
		converter = mc
		loading.set_detail("Mock data (synthetic placeholder content)" + ("" if args.seed_cache == "" else ", real CS2/machines from " + args.seed_cache))
	else:
		if args.game_dir == "":
			show_error("The CS2 folder was not given. Start Horizon Strike from Melty (it passes --game <CS2 folder>).")
			return
		var vpk := Paths.norm(args.game_dir).path_join("game/csgo/pak01_dir.vpk")
		if not FileAccess.file_exists(vpk):
			show_error("Counter-Strike 2 was not found in %s (missing game/csgo/pak01_dir.vpk)." % args.game_dir)
			return
		var exe := Paths.converter_exe(args.converter_exe)
		if exe == "":
			show_error("The converter (converter/hzsconv.exe) is missing next to the game.")
			return
		var cc := ConverterClient.new()
		cc.name = "Converter"
		add_child(cc)
		var workers := int(Sheets.sys_num("streaming.max_concurrent_conversions", 2))
		var err: String = cc.start(exe, PackedStringArray(["serve", "--cs2", Paths.norm(args.game_dir), "--hzd", hzd_dir,
			"--cache", Game.cache_root, "--workers", str(workers)]))
		if err != "":
			show_error(err)
			return
		converter = cc
		Game.converter_pid = cc.pid
		loading.set_detail("Converting content from your own CS2 and Horizon Zero Dawn installs into %s" % Game.cache_root)
	converter.event_received.connect(_on_converter_event)
	var start_dir := Game.cache_root.path_join("hzd/cells/%d_%d" % [start_cell.x, start_cell.y])
	var had_start := FileAccess.file_exists(start_dir.path_join("cell.json"))
	if not had_start:
		Game.cells_converted += 1
	_bootstrap_id = converter.send({"op": "bootstrap", "radius": 0})
	Log.info("bootstrap requested (id %d, radius 0, start cell %s on disk: %s)" % [_bootstrap_id, start_cell, had_start])


func _on_converter_event(e: Dictionary) -> void:
	var ev := str(e.get("event", ""))
	var id := int(e.get("id", -1))
	if ev == "exit":
		if _quitting:
			return
		if _phase == "bootstrap" or _phase == "world":
			show_error("The converter stopped unexpectedly.")
		else:
			Log.warn("converter exited")
		return
	if id != _bootstrap_id:
		return
	match ev:
		"progress":
			if loading:
				loading.set_stage(str(e.get("stage", "")), int(e.get("done", 0)), int(e.get("total", 1)))
			Log.info("bootstrap %s %d/%d" % [e.get("stage", ""), int(e.get("done", 0)), int(e.get("total", 1))])
		"done":
			Log.info("bootstrap done (%d bytes) after %.1f s" % [int(e.get("bytes", 0)), Time.get_ticks_msec() / 1000.0 - _t_start])
			_on_bootstrapped()
		"error":
			if _cache_playable():
				Log.warn("bootstrap failed (%s); the cache already holds weapons, the world index and the start cell -> continuing with the cached content" % e.get("message", ""))
				_on_bootstrapped()
			else:
				show_error("Converting failed: %s" % e.get("message", "unknown error"))


## Everything needed to play is already converted (a converter failure then only costs new cells).
func _cache_playable() -> bool:
	var root := Game.cache_root
	if not FileAccess.file_exists(root.path_join("cs2/weapons.json")) or not FileAccess.file_exists(root.path_join("hzd/index.json")):
		return false
	var idx = FsUtil.read_json(root.path_join("hzd/index.json"))
	if typeof(idx) != TYPE_DICTIONARY or not idx.has("start_cell"):
		return false
	var sc: Array = idx["start_cell"]
	return FileAccess.file_exists(root.path_join("hzd/cells/%d_%d/cell.json" % [int(sc[0]), int(sc[1])]))


func _on_bootstrapped() -> void:
	_phase = "world"
	Sheets.load_resolved(Game.cache_root)
	apply_render_settings()
	for err in Sheets.resolved_errors:
		Log.warn("resolved data: " + err)
	var idx = FsUtil.read_json(Game.cache_root.path_join("hzd/index.json"))
	if typeof(idx) != TYPE_DICTIONARY:
		show_error("The world index (hzd/index.json) is missing after conversion.")
		return
	index = idx
	if index.has("start_cell"):
		start_cell = Vector2i(int(index["start_cell"][0]), int(index["start_cell"][1]))
	Game.last_campfire_id = str(index.get("start_campfire", ""))
	Game.money = int(Sheets.sys_num("economy.start_money", 800))
	world = World.new()
	world.name = "World"
	add_child(world)
	Game.world = world
	world.setup(Game.cache_root, index, converter)
	Game.cell_loaded.connect(_on_cell_loaded)
	if loading:
		loading.set_stage("cell", 0, 1)
	world.request_ring_now()


func _on_cell_loaded(c: Vector2i) -> void:
	if _phase != "world":
		return
	var sp: Array = index.get("start_pos", [])
	var pos: Vector3 = world.cell_origin(start_cell) + Vector3(world.cell_size * 0.5, 0, world.cell_size * 0.5)
	if sp.size() == 3:
		pos = Vector3(float(sp[0]), float(sp[1]), float(sp[2]))
	if world.cell_of(pos) != c and c != start_cell:
		return
	_spawn_player(pos)


func _spawn_player(pos: Vector3) -> void:
	_phase = "play"
	player = Player.new()
	world.add_child(player)
	Game.player = player
	var gh: float = world.height_at(pos)
	if not is_nan(gh):
		pos.y = maxf(pos.y, gh + 0.05)
	player.teleport(pos)
	# face the start campfire / cell centre
	var hud := Hud.new()
	hud.name = "HUD"
	add_child(hud)
	Game.hud = hud
	var bw := BuyWheel.new()
	bw.name = "BuyWheelLayer"
	add_child(bw)
	var sm := SettingsMenu.new()
	sm.name = "SettingsLayer"
	add_child(sm)
	SettingsMenu.apply_window_mode()
	var ad := AudioDirector.new()
	ad.name = "AudioDirector"
	add_child(ad)
	Log.info("player spawned at %s; money $%d; inventory %s" % [pos, Game.money, player.inventory])
	# shaders and pipelines compile under the loading screen, then the world is ready (H8)
	var pre := Precompile.new()
	pre.name = "Precompile"
	pre.camera = player.camera
	pre.meshes = world.meshes
	pre.spawner = world.spawner
	pre.viewmodel = player.weapons.viewmodel if player.get("weapons") else null
	pre.loading = loading
	world.add_child(pre)
	pre.finished.connect(func() -> void:
		Game.bootstrap_seconds = Time.get_ticks_msec() / 1000.0 - _t_start
		if loading:
			loading.queue_free()
			loading = null
		capture_mouse()
		Game.mark_world_ready())
	pre.start()


# ------------------------------------------------------------------ death / respawn

func on_player_died() -> void:
	_death_pos = player.global_position
	_respawn_left = Sheets.sys_num("respawn.delay_s", 3.0)
	if Game.hud:
		Game.hud.show_death(_respawn_left)
	if Game.buy_wheel:
		Game.buy_wheel.close()


func _process(delta: float) -> void:
	if _respawn_left >= 0.0:
		_respawn_left -= delta
		if _respawn_left < 0.0:
			_respawn()
	if _phase == "play" and player and player.is_alive():
		_check_campfires()


func _respawn() -> void:
	var cf_id := Game.last_campfire_id
	if cf_id == "":
		cf_id = str(index.get("start_campfire", ""))
	var pos := Vector3.ZERO
	var yaw := 0.0
	var node: Node3D = Game.campfires.get(cf_id)
	if node and is_instance_valid(node):
		pos = node.respawn_point()
	elif world.campfire_positions.has(cf_id):
		pos = (world.campfire_positions[cf_id] as Vector3) + Vector3(1.6, 0.1, 0.0)
	else:
		var sp: Array = index.get("start_pos", [0, 0, 0])
		pos = Vector3(float(sp[0]), float(sp[1]), float(sp[2]))
	if Sheets.sys_bool("respawn.reset_machine_alert", true):
		var r := Sheets.sys_num("spawning.activation_radius_m", 250.0)
		for m in Game.machines.duplicate():
			if is_instance_valid(m) and (m.global_position.distance_to(_death_pos) <= r or m.state in ["alert", "attack"]):
				m.reset_calm()
	player.respawn_at(pos, yaw)
	if Game.hud:
		Game.hud.hide_death()
	Log.info("player respawned at campfire %s (%s); money $%d; inventory %s" % [cf_id, pos, Game.money, player.inventory])
	Game.player_respawned.emit(cf_id)


func _check_campfires() -> void:
	var r := Sheets.sys_num("respawn.campfire_activate_radius_m", 4.0)
	for id in Game.campfires:
		var c: Node3D = Game.campfires[id]
		if is_instance_valid(c) and c.global_position.distance_to(player.global_position) <= r:
			Game.activate_campfire(id)


# ------------------------------------------------------------------ misc

## Automated runs (autotest, dev --script tools, --exit-after) never grab the user's mouse.
func capture_mouse() -> void:
	if args.automated() or DisplayServer.get_name() == "headless":
		return
	if player and player.is_alive() and Game.is_world_ready:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		var menus_open: bool = (Game.buy_wheel and Game.buy_wheel.is_open()) or get_tree().paused
		if not menus_open:
			capture_mouse()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit_game(0)


func quit_game(code: int) -> void:
	if _quitting:
		return
	_quitting = true
	Log.info("quitting (%d)" % code)
	if converter and converter.has_method("stop"):
		converter.stop()
	get_tree().quit(code)


func _make_environment() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	_sky_mat = ProceduralSkyMaterial.new()
	sky.sky_material = _sky_mat
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env.fog_enabled = true
	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)
	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.shadow_enabled = true
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	add_child(_sun)
	apply_render_settings()


## Fixed morning (render.time_of_day_h) from the render.* rows; the HZD-bound rows resolve after the converter wrote
## hzd/systems.json, so this runs again once the resolved values are loaded.
## HZD -> Godot: sun azimuth from north (-Z) towards east (+X), elevation above the horizon; fog start/end as depth
## fog, its density row (percent) as the maximum fog amount, fog height + falloff as height fog; sky colour on the
## zenith, a lighter mix on the horizon; the fog takes the sky colour (aerial perspective).
func apply_render_settings() -> void:
	var elev := deg_to_rad(Sheets.sys_num("render.sun_elevation_deg", 35.0))
	var az := deg_to_rad(Sheets.sys_num("render.sun_azimuth_deg", 120.0))
	var to_sun := Vector3(sin(az) * cos(elev), sin(elev), -cos(az) * cos(elev)).normalized()
	_sun.basis = Basis.looking_at(-to_sun, Vector3.UP if absf(to_sun.y) < 0.99 else Vector3.FORWARD)
	_sun.light_energy = Sheets.sys_num("render.sun_energy", 1.6)
	# low morning sun: a little warm
	_sun.light_color = Color(1.0, 0.95, 0.86).lerp(Color.WHITE, clampf(rad_to_deg(elev) / 45.0, 0.0, 1.0))
	_sun.light_angular_distance = clampf(Sheets.sys_num("render.sun_shape_size", 0.5), 0.1, 5.0)
	_sun.directional_shadow_max_distance = Sheets.sys_num("render.shadow_distance_m", 100.0)
	var sky_c := _color_row("render.sky_color", Color(0.32, 0.5, 0.75))
	_sky_mat.sky_top_color = sky_c.lerp(Color(0.2, 0.35, 0.6), 0.45)
	_sky_mat.sky_horizon_color = sky_c.lerp(Color(0.86, 0.89, 0.92), 0.7)
	_sky_mat.ground_horizon_color = _sky_mat.sky_horizon_color.darkened(0.15)
	_sky_mat.ground_bottom_color = Color(0.25, 0.25, 0.22)
	_sky_mat.sun_angle_max = 20.0
	_env.ambient_light_energy = Sheets.sys_num("render.ambient_energy", 0.6)
	_env.tonemap_mode = Environment.TONE_MAPPER_AGX if str(Sheets.sys("render.tonemap")) == "agx" else Environment.TONE_MAPPER_FILMIC
	_env.tonemap_exposure = Sheets.sys_num("render.exposure", 1.0)
	_env.fog_mode = Environment.FOG_MODE_DEPTH
	_env.fog_depth_begin = Sheets.sys_num("render.fog_start_m", 50.0)
	_env.fog_depth_end = maxf(Sheets.sys_num("render.fog_end_m", 950.0), _env.fog_depth_begin + 10.0)
	_env.fog_depth_curve = 1.6
	_env.fog_density = clampf(Sheets.sys_num("render.fog_density", 60.0) / 100.0, 0.0, 1.0)
	_env.fog_light_color = _color_row("render.fog_color", Color(0.8, 0.85, 0.9)).lerp(_sky_mat.sky_horizon_color, 0.5)
	_env.fog_aerial_perspective = 0.6
	_env.fog_sky_affect = 0.25
	_env.fog_sun_scatter = 0.15
	_env.fog_height = Sheets.sys_num("render.fog_height_m", 0.0)
	# HZD falloff is per metre of an exponential; Godot adds height_density per metre below fog_height to the depth
	# fog amount (0.16 gave a white sheet over the village) -> scaled down to a light valley haze
	_env.fog_height_density = Sheets.sys_num("render.fog_height_falloff", 0.0) * 0.02
	_env.volumetric_fog_enabled = Sheets.sys_bool("render.volumetric_fog", false)
	get_viewport().mesh_lod_threshold = Sheets.sys_num("render.lod_threshold_px", 12.0)
	Log.info("render: sun elevation %.1f az %.1f, fog %.0f-%.0f m x%.2f, height fog %.0f m %.3f, tonemap %s" % [rad_to_deg(elev), rad_to_deg(az),
		_env.fog_depth_begin, _env.fog_depth_end, _env.fog_density, _env.fog_height, _env.fog_height_density, Sheets.sys("render.tonemap")])


func _color_row(id: String, fallback: Color) -> Color:
	var v: Variant = Sheets.sys(id)
	if v is Array and (v as Array).size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]))
	return fallback
