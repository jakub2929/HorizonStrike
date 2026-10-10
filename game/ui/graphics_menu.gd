extends CanvasLayer
## Esc menu page "Graphics" (owner vykon): presets low / medium / high and the manual options of the
## GraphicsSettings autoload; every change is applied and saved at once. Opened by the "Graphics" button that
## make_button() puts into the Esc menu (one GRAPHICS HOOK line in ui/settings_menu.gd); Back or Esc returns.
##
## Every choice is a toggle button (no popups), so tests can click it by name:
##   GraphicsMenu, PresetLow/PresetMedium/PresetHigh, PresetLabel, FpsLimit_<n> (0 = unlimited), VSync,
##   RenderScale (HSlider) + RenderScaleLabel, Fsr, ShadowQuality_<off|low|medium|high>, ShadowDistance_<m>,
##   VegDistance_<x100>, VegDensity_<x100>, LodBias_<x100>, TextureQuality_<full|half>, Ssao, Ssr, VolumetricFog,
##   GpuLabel, GraphicsBack.

const GS := preload("res://settings/graphics_settings.gd")

var _root: Control
var _preset_label: Label
var _scale_label: Label
var _scale: HSlider
var _choices := {}     ## setting key -> {value_string: Button}
var _checks := {}      ## setting key -> CheckButton
var _gpu_label: Label
var _syncing := false


## The Esc menu button that opens this page (created lazily as a child of `host`).
static func make_button(host: Node) -> Button:
	var b := Button.new()
	b.name = "GraphicsButton"
	b.text = "Graphics"
	b.pressed.connect(func() -> void:
		var m: Node = host.get_node_or_null("GraphicsMenuLayer")
		if m == null:
			m = load("res://ui/graphics_menu.gd").new()
			m.name = "GraphicsMenuLayer"
			host.add_child(m)
		m.open())
	return b


func _ready() -> void:
	layer = 26
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.name = "GraphicsMenu"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.94)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_root.add_child(scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	center.add_child(box)
	var t := Label.new()
	t.text = "Graphics"
	t.add_theme_font_size_override("font_size", 32)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 6)
	box.add_child(grid)

	# presets
	var prow := _row(grid, "Preset")
	for p in GS.preset_order():
		var b := Button.new()
		b.name = "Preset" + str(p).capitalize()
		b.text = str(p).capitalize()
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(96, 0)
		b.pressed.connect(func() -> void: GraphicsSettings.set_preset(str(p)))
		prow.add_child(b)
		_choice_add("preset", str(p), b)
	_preset_label = Label.new()
	_preset_label.name = "PresetLabel"
	prow.add_child(_preset_label)

	var fps_labels := {}
	for v in GS.list_row("graphics.fps_limits", [30, 60, 120, 144, 0]):
		fps_labels[int(v)] = "Unlimited" if int(v) == 0 else str(int(v))
	_choice_row(grid, "FPS limit", "fps_limit", "FpsLimit", fps_labels)
	_check_row(grid, "VSync", "vsync", "VSync")

	var srow := _row(grid, "Render scale")
	var r := GS.list_row("graphics.render_scale_range", [0.5, 1.0, 0.05])
	_scale = HSlider.new()
	_scale.name = "RenderScale"
	_scale.min_value = float(r[0])
	_scale.max_value = float(r[1])
	_scale.step = float(r[2]) if r.size() > 2 else 0.05
	_scale.custom_minimum_size = Vector2(260, 24)
	_scale.value_changed.connect(func(v: float) -> void:
		_scale_label.text = "%d %%" % roundi(v * 100.0)
		if not _syncing:
			GraphicsSettings.set_value("render_scale", v))
	srow.add_child(_scale)
	_scale_label = Label.new()
	_scale_label.name = "RenderScaleLabel"
	srow.add_child(_scale_label)
	_check_row(grid, "FSR upscaling", "fsr", "Fsr")

	var sq := {}
	for q in GS.list_row("graphics.shadow_quality_order", ["off", "low", "medium", "high"]):
		sq[str(q)] = str(q).capitalize()
	_choice_row(grid, "Shadow quality", "shadow_quality", "ShadowQuality", sq)
	_choice_row(grid, "Shadow distance", "shadow_distance", "ShadowDistance",
		_num_labels(GS.list_row("graphics.shadow_distance_steps", [50, 75, 100, 150, 200]), " m", 1.0))
	_choice_row(grid, "Vegetation distance", "veg_distance", "VegDistance",
		_num_labels(GS.list_row("graphics.veg_distance_steps", [0.5, 0.75, 1.0, 1.25]), " %", 100.0))
	_choice_row(grid, "Vegetation density", "veg_density", "VegDensity",
		_num_labels(GS.list_row("graphics.veg_density_steps", [0.25, 0.5, 0.75, 1.0]), " %", 100.0))
	_choice_row(grid, "LOD bias", "lod_bias", "LodBias",
		_num_labels(GS.list_row("graphics.lod_bias_steps", [0.5, 0.75, 1.0, 1.5]), " %", 100.0))
	_choice_row(grid, "Textures (new areas)", "texture_quality", "TextureQuality", {"full": "Full", "half": "Half"})
	_check_row(grid, "SSAO", "ssao", "Ssao")
	_check_row(grid, "SSR", "ssr", "Ssr")
	_check_row(grid, "Volumetric fog", "volumetric_fog", "VolumetricFog")

	_gpu_label = Label.new()
	_gpu_label.name = "GpuLabel"
	_gpu_label.modulate = Color(1, 1, 1, 0.7)
	box.add_child(_gpu_label)
	var back := Button.new()
	back.name = "GraphicsBack"
	back.text = "Back"
	back.pressed.connect(close)
	box.add_child(back)
	GraphicsSettings.changed.connect(func(_k: String) -> void: _sync())


func _row(grid: GridContainer, title: String) -> HBoxContainer:
	var l := Label.new()
	l.text = title
	grid.add_child(l)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	grid.add_child(h)
	return h


## value -> label for numeric steps; the node suffix is the value x node_mult (e.g. VegDensity_50).
func _num_labels(values: Array, unit: String, mult: float) -> Dictionary:
	var out := {}
	for v in values:
		out[float(v)] = "%d%s" % [roundi(float(v) * mult), unit]
	return out


func _choice_row(grid: GridContainer, title: String, key: String, node_prefix: String, labels: Dictionary) -> void:
	var h := _row(grid, title)
	var mult := 100.0 if key in ["veg_distance", "veg_density", "lod_bias"] else 1.0
	for v in labels:
		var b := Button.new()
		var suffix := str(v) if typeof(v) == TYPE_STRING else str(roundi(float(v) * mult))
		b.name = "%s_%s" % [node_prefix, suffix]
		b.text = str(labels[v])
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(72, 0)
		b.pressed.connect(func() -> void:
			if not _syncing:
				GraphicsSettings.set_value(key, v)
			_sync())
		h.add_child(b)
		_choice_add(key, _key_of(v), b)


func _check_row(grid: GridContainer, title: String, key: String, node_name: String) -> void:
	var h := _row(grid, title)
	var c := CheckButton.new()
	c.name = node_name
	c.toggled.connect(func(on: bool) -> void:
		if not _syncing:
			GraphicsSettings.set_value(key, on))
	h.add_child(c)
	_checks[key] = c


func _choice_add(key: String, value_key: String, b: Button) -> void:
	if not _choices.has(key):
		_choices[key] = {}
	_choices[key][value_key] = b


static func _key_of(v: Variant) -> String:
	if typeof(v) == TYPE_STRING:
		return v
	return "%.3f" % float(v)


## Shows the current values (after open and after every change, also changes made elsewhere).
func _sync() -> void:
	_syncing = true
	for key in _choices:
		var cur: Variant = GraphicsSettings.preset if key == "preset" else GraphicsSettings.get_value(key)
		var ck := _key_of(cur) if typeof(cur) == TYPE_STRING else _key_of(float(cur))
		for vk in _choices[key]:
			(_choices[key][vk] as Button).set_pressed_no_signal(vk == ck)
	for key in _checks:
		(_checks[key] as CheckButton).set_pressed_no_signal(bool(GraphicsSettings.get_value(key)))
	_scale.set_value_no_signal(GraphicsSettings.render_scale)
	_scale_label.text = "%d %%" % roundi(GraphicsSettings.render_scale * 100.0)
	_preset_label.text = "(custom)" if GraphicsSettings.preset == "custom" else ""
	var a: Dictionary = GraphicsSettings.auto_info
	_gpu_label.text = "GPU: %s, %s VRAM, first-start preset %s" % [a.get("gpu", "?"),
		"%d MiB" % int(a.get("vram_mib", 0)) if int(a.get("vram_mib", 0)) > 0 else "unknown", a.get("preset", "?")]
	_syncing = false


func is_open() -> bool:
	return _root != null and _root.visible


func open() -> void:
	_sync()
	_root.visible = true


func close() -> void:
	_root.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if is_open() and event.is_action_pressed("menu"):
		close()
		get_viewport().set_input_as_handled()
