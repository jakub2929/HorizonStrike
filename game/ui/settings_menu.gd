extends CanvasLayer
## Esc menu: cache cap (cache.min_cap_gib..cache.max_cap_gib, saved in settings.json), current cache size,
## mouse sensitivity, volume, resume, quit. Pauses the game while open.

const Sheets := preload("res://core/sheets.gd")
const Settings := preload("res://core/settings.gd")
const Hud := preload("res://ui/hud.gd")

const GIB := 1073741824.0

var _root: Control
var _cap: HSlider
var _cap_l: Label
var _size_l: Label
var _sens: HSlider
var _vol: HSlider
var _open := false


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
	var resume := Button.new()
	resume.text = "Resume"
	resume.pressed.connect(close)
	box.add_child(resume)
	var quit := Button.new()
	quit.text = "Quit"
	quit.pressed.connect(func(): get_tree().quit(0))
	box.add_child(quit)


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
	get_tree().paused = false
	if Game.main and Game.main.has_method("capture_mouse"):
		Game.main.capture_mouse()


func _process(_delta: float) -> void:
	if _open:
		_size_l.text = "Cache size on disk: %s  (%s)" % [Hud.human_bytes(Game.cache_bytes()), Game.cache_root]


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu"):
		if Game.buy_wheel and Game.buy_wheel.is_open():
			return
		if _open:
			close()
		elif Game.is_world_ready:
			open()
		get_viewport().set_input_as_handled()
