extends CanvasLayer
## Esc menu: cache cap (cache.min_cap_gib..cache.max_cap_gib, saved in settings.json), current cache size,
## mouse sensitivity, volume, fullscreen, knife (0.3: list of the CS2 knife models in the cache with a rotating 3D
## preview; the choice is saved and the knife slot shows it), resume, quit. Pauses the game while open.
## Node names for tests (real input only): SettingsMenu/.../KnifeButton, KnifePanel/.../KnifeList (ItemList, one item
## per knife, metadata = knife id), KnifePreview (SubViewportContainer), KnifeBack.

const Sheets := preload("res://core/sheets.gd")
const Settings := preload("res://core/settings.gd")
const Hud := preload("res://ui/hud.gd")
const Knives := preload("res://core/knives.gd")
const Content := preload("res://core/content.gd")
const Log := preload("res://core/log.gd")

const GIB := 1073741824.0
const PREVIEW_SIZE := 1.1         # longest edge of the previewed knife (preview units)
const PREVIEW_DEG_PER_S := 40.0

var _root: Control
var _cap: HSlider
var _cap_l: Label
var _size_l: Label
var _sens: HSlider
var _vol: HSlider
var _open := false
var _main_box: Control
var _knife_panel: Control
var _knife_list: ItemList
var _preview_vp: SubViewport
var _preview_pivot: Node3D
var _preview_model: Node3D
var _preview_id := ""


func _ready() -> void:
	layer = 25
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.name = "SettingsMenu"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-300, -230)
	box.size = Vector2(600, 460)
	box.add_theme_constant_override("separation", 12)
	_root.add_child(box)
	var t := Label.new()
	t.text = "Paused"
	t.add_theme_font_size_override("font_size", 36)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)
	_cap_l = Label.new()
	box.add_child(_cap_l)
	_cap = HSlider.new()
	_cap.min_value = Sheets.sys_num("cache.min_cap_gib", 1.0)
	_cap.max_value = Sheets.sys_num("cache.max_cap_gib", 64.0)
	_cap.step = 0.5
	_cap.custom_minimum_size = Vector2(600, 24)
	_cap.value_changed.connect(_on_cap)
	box.add_child(_cap)
	_size_l = Label.new()
	box.add_child(_size_l)
	var sl := Label.new()
	sl.text = "Mouse sensitivity"
	box.add_child(sl)
	_sens = HSlider.new()
	_sens.min_value = 0.2
	_sens.max_value = 4.0
	_sens.step = 0.05
	_sens.value = float(Settings.get_value("mouse_sensitivity", 1.0))
	_sens.value_changed.connect(_on_sens)
	box.add_child(_sens)
	var vl := Label.new()
	vl.text = "Volume"
	box.add_child(vl)
	_vol = HSlider.new()
	_vol.min_value = 0.0
	_vol.max_value = 1.0
	_vol.step = 0.05
	_vol.value = float(Settings.get_value("volume", 0.8))
	_vol.value_changed.connect(_on_vol)
	box.add_child(_vol)
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(_vol.value, 0.0001)))
	var fs := CheckButton.new()
	fs.text = "Fullscreen"
	fs.button_pressed = bool(Settings.get_value("fullscreen", false))
	fs.toggled.connect(_on_fullscreen)
	box.add_child(fs)
	var knife := Button.new()
	knife.name = "KnifeButton"
	knife.text = "Knife"
	knife.pressed.connect(_open_knives)
	box.add_child(knife)
	var resume := Button.new()
	resume.name = "ResumeButton"
	resume.text = "Resume"
	resume.pressed.connect(close)
	box.add_child(resume)
	var quit := Button.new()
	quit.text = "Quit"
	quit.pressed.connect(func(): Game.quit(0))
	box.add_child(quit)
	_main_box = box
	_build_knife_panel()


# ------------------------------------------------------------------ knife (0.3)

func _build_knife_panel() -> void:
	_knife_panel = VBoxContainer.new()
	_knife_panel.name = "KnifePanel"
	_knife_panel.set_anchors_preset(Control.PRESET_CENTER)
	_knife_panel.position = Vector2(-430, -260)
	_knife_panel.size = Vector2(860, 520)
	_knife_panel.add_theme_constant_override("separation", 12)
	_knife_panel.visible = false
	_root.add_child(_knife_panel)
	var t := Label.new()
	t.text = "Knife"
	t.add_theme_font_size_override("font_size", 36)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_knife_panel.add_child(t)
	var note := Label.new()
	note.text = "Choose a knife model from your own CS2 install. Every knife hits like the default knife."
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_knife_panel.add_child(note)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	_knife_panel.add_child(row)
	_knife_list = ItemList.new()
	_knife_list.name = "KnifeList"
	_knife_list.custom_minimum_size = Vector2(380, 400)
	_knife_list.select_mode = ItemList.SELECT_SINGLE
	_knife_list.item_selected.connect(_on_knife_item)
	row.add_child(_knife_list)
	var cont := SubViewportContainer.new()
	cont.name = "KnifePreview"
	cont.custom_minimum_size = Vector2(400, 400)
	cont.stretch = true
	cont.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(cont)
	_preview_vp = SubViewport.new()
	_preview_vp.name = "KnifePreviewViewport"
	_preview_vp.own_world_3d = true
	_preview_vp.transparent_bg = false
	_preview_vp.msaa_3d = Viewport.MSAA_4X
	_preview_vp.gui_disable_input = true
	_preview_vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	cont.add_child(_preview_vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.1, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.76)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	_preview_vp.add_child(we)
	var key := DirectionalLight3D.new()
	key.light_energy = 1.6
	key.rotation_degrees = Vector3(-35, 35, 0)
	_preview_vp.add_child(key)
	var rim := DirectionalLight3D.new()
	rim.light_energy = 0.7
	rim.light_color = Color(0.8, 0.85, 1.0)
	rim.rotation_degrees = Vector3(-20, 200, 0)
	_preview_vp.add_child(rim)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0.15, 1.6)
	cam.look_at_from_position(cam.position, Vector3.ZERO)
	cam.fov = 40.0
	cam.current = true
	_preview_vp.add_child(cam)
	_preview_pivot = Node3D.new()
	_preview_pivot.name = "Pivot"
	_preview_vp.add_child(_preview_pivot)
	var back := Button.new()
	back.name = "KnifeBack"
	back.text = "Back"
	back.pressed.connect(_close_knives)
	_knife_panel.add_child(back)


func _open_knives() -> void:
	Knives.reload()
	_knife_list.clear()
	var sel := Knives.selected()
	for k in Knives.available():
		var i := _knife_list.add_item(str(k["name"]))
		_knife_list.set_item_metadata(i, str(k["id"]))
		if str(k["id"]) == sel:
			_knife_list.select(i)
	_main_box.visible = false
	_knife_panel.visible = true
	_knife_list.grab_focus()
	_show_preview(sel)


func _close_knives() -> void:
	_knife_panel.visible = false
	_main_box.visible = true
	_clear_preview()


## A knife picked in the list (mouse or keyboard): saved, previewed and, when the knife is drawn, shown in hand.
func _on_knife_item(i: int) -> void:
	var id := str(_knife_list.get_item_metadata(i))
	if id == Knives.selected():
		_show_preview(id)
		return
	if Knives.select(id):
		_show_preview(id)
		var vm: Node = Game.player.weapons.viewmodel if Game.player and Game.player.get("weapons") else null
		if vm and vm.has_method("refresh_knife"):
			vm.refresh_knife()


func _show_preview(id: String) -> void:
	if id == _preview_id and _preview_model:
		return
	_clear_preview()
	_preview_id = id
	var key := Knives.key_of(id)
	var path := Content.weapon_world_model(key)
	var node: Node3D = null
	if path != "":
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		if doc.append_from_file(path, st) == OK:
			var scene := doc.generate_scene(st)
			if scene is Node3D:
				node = scene
			elif scene:
				scene.free()
	if node == null:
		node = _preview_placeholder()
		Log.info("knife preview %s: no world.glb, placeholder" % id)
	var box := _aabb_of(node, Transform3D.IDENTITY)
	var longest := maxf(box.get_longest_axis_size(), 0.001)
	var s := PREVIEW_SIZE / longest
	var holder := Node3D.new()
	holder.add_child(node)
	# lie the blade along the screen: the longest axis becomes X
	var axis := box.get_longest_axis_index()
	if axis == Vector3.AXIS_Y:
		holder.rotation_degrees = Vector3(0, 0, 90)
	elif axis == Vector3.AXIS_Z:
		holder.rotation_degrees = Vector3(0, 90, 0)
	node.scale = Vector3.ONE * s
	node.position = -box.get_center() * s
	_preview_model = holder
	_preview_pivot.add_child(holder)


func _clear_preview() -> void:
	if _preview_model:
		_preview_model.queue_free()
	_preview_model = null
	_preview_id = ""


static func _aabb_of(n: Node, xf: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [[n, xf]]
	while not stack.is_empty():
		var e: Array = stack.pop_back()
		var node: Node = e[0]
		var t: Transform3D = e[1]
		if node is Node3D and node != n:
			t = t * (node as Node3D).transform
		if node is MeshInstance3D and (node as MeshInstance3D).mesh:
			var b: AABB = t * (node as MeshInstance3D).mesh.get_aabb()
			out = b if first else out.merge(b)
			first = false
		for c in node.get_children():
			stack.append([c, t])
	return out if not first else AABB(Vector3(-0.1, -0.02, -0.01), Vector3(0.2, 0.04, 0.02))


func _preview_placeholder() -> Node3D:
	var root := Node3D.new()
	var blade := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.18, 0.035, 0.008)
	blade.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.75, 0.76, 0.78)
	m.metallic = 0.9
	m.roughness = 0.25
	blade.material_override = m
	blade.position = Vector3(0.05, 0, 0)
	root.add_child(blade)
	var grip := MeshInstance3D.new()
	var gm := BoxMesh.new()
	gm.size = Vector3(0.11, 0.03, 0.02)
	grip.mesh = gm
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color(0.12, 0.12, 0.13)
	grip.material_override = dm
	grip.position = Vector3(-0.09, 0, 0)
	root.add_child(grip)
	return root


func _on_fullscreen(on: bool) -> void:
	Settings.set_value("fullscreen", on)
	apply_window_mode()


## Applies the saved window mode (never in automated runs: they keep the default window).
static func apply_window_mode() -> void:
	if Game.args and Game.args.automated():
		return
	if DisplayServer.get_name() == "headless":
		return
	var on := bool(Settings.get_value("fullscreen", false))
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)


func _on_sens(v: float) -> void:
	Settings.set_value("mouse_sensitivity", v)
	if Game.player:
		Game.player.set_sensitivity(v)


func _on_vol(v: float) -> void:
	Settings.set_value("volume", v)
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(v, 0.0001)))


func _on_cap(v: float) -> void:
	Game.set_cache_cap(int(v * GIB), true)
	_cap_l.text = "Cache limit: %.1f GiB (far cells are deleted above it and converted again on return)" % v


func is_open() -> bool:
	return _open


func open() -> void:
	_open = true
	_root.visible = true
	_cap.set_value_no_signal(float(Game.cache_cap_bytes) / GIB)
	_cap_l.text = "Cache limit: %.1f GiB (far cells are deleted above it and converted again on return)" % _cap.value
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	_open = false
	_root.visible = false
	if _knife_panel.visible:
		_close_knives()
	get_tree().paused = false
	if Game.main and Game.main.has_method("capture_mouse"):
		Game.main.capture_mouse()


func _process(delta: float) -> void:
	if _open:
		_size_l.text = "Cache size on disk: %s  (%s)" % [Hud.human_bytes(Game.cache_bytes()), Game.cache_root]
		if _knife_panel.visible and _preview_pivot:
			_preview_pivot.rotate_y(deg_to_rad(PREVIEW_DEG_PER_S) * delta)


## Esc opens / closes the menu, also in automated runs (0.3: tests choose the knife through the menu with input
## events; an Esc the user presses into a focused test window pauses that run like in play).
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu"):
		if Game.buy_wheel and Game.buy_wheel.is_open():
			return
		if _open:
			close()
		elif Game.is_world_ready:
			open()
		get_viewport().set_input_as_handled()
