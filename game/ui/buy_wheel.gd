extends CanvasLayer
## Radial buy wheel (D6/D14: weapons rows with buy_wheel_index >= 0, max economy.buy_wheel_max_items) with resolved
## prices and icons (cache cs2/weapons/<id>/icon.svg via Image.load_svg_from_buffer). Buying goes through Game.buy
## (refused in combat, D19). B toggles, mouse direction selects, left click buys.

const Sheets := preload("res://core/sheets.gd")
const Log := preload("res://core/log.gd")
const SoundLib := preload("res://audio/sound_lib.gd")

const RADIUS := 290.0
const INNER := 95.0

var _root: Control
var _wheel: Control
var _items: Array[String] = []
var _slots: Array = []      # Control per item
var _icons := {}
var _sel := -1
var _open := false
var _status: Label
var _sfx: AudioStreamPlayer


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.name = "BuyWheel"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	_wheel = Control.new()
	_wheel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_wheel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wheel.draw.connect(_draw_wheel)
	_root.add_child(_wheel)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 20)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status.add_theme_color_override("font_outline_color", Color.BLACK)
	_status.add_theme_constant_override("outline_size", 6)
	_root.add_child(_status)
	_sfx = AudioStreamPlayer.new()
	add_child(_sfx)
	_build_items()
	Game.buy_wheel = self


func _build_items() -> void:
	for s in _slots:
		(s as Node).queue_free()
	_slots.clear()
	_items = Sheets.buy_wheel_ids()
	for id in _items:
		var slot := VBoxContainer.new()
		slot.name = "BuyItem_" + id
		slot.alignment = BoxContainer.ALIGNMENT_CENTER
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.size = Vector2(130, 90)
		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(110, 40)
		icon.texture = _icon(id)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(icon)
		var name_l := Label.new()
		name_l.name = "Name"
		name_l.text = str(Sheets.weapon_row(id).get("display_name", id))
		name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_l.add_theme_font_size_override("font_size", 15)
		slot.add_child(name_l)
		var price_l := Label.new()
		price_l.name = "Price"
		price_l.text = "$%d" % Sheets.price(id)
		price_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		price_l.add_theme_font_size_override("font_size", 15)
		slot.add_child(price_l)
		_wheel.add_child(slot)
		_slots.append(slot)


func _icon(id: String) -> Texture2D:
	if _icons.has(id):
		return _icons[id]
	var tex: Texture2D = null
	var p := Game.cache_root.path_join("cs2/weapons/%s/icon.svg" % id)
	if FileAccess.file_exists(p):
		var img := Image.new()
		if img.load_svg_from_buffer(FileAccess.get_file_as_bytes(p), 1.0) == OK:
			var h := img.get_height()
			if h > 0 and h != 48:
				img = Image.new()
				var sc := 48.0 / float(h)
				img.load_svg_from_buffer(FileAccess.get_file_as_bytes(p), sc)
			tex = ImageTexture.create_from_image(img)
	_icons[id] = tex
	return tex


func refresh_prices() -> void:
	_icons.clear()
	_build_items()


func is_open() -> bool:
	return _open


func open() -> void:
	if _open:
		return
	_open = true
	_root.visible = true
	_sel = -1
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var vp := _root.get_viewport_rect().size
	if DisplayServer.get_name() != "headless":
		Input.warp_mouse(vp * 0.5)
	_layout()
	Log.info("buy wheel opened (%d items)" % _items.size())


func close() -> void:
	if not _open:
		return
	_open = false
	_root.visible = false
	if Game.main and Game.main.has_method("capture_mouse"):
		Game.main.capture_mouse()
	Log.info("buy wheel closed")


func on_bought(_id: String) -> void:
	var s: AudioStream = SoundLib.random_stream(Game.cache_root.path_join("cs2/ui"), "radial_menu_buy")
	if s:
		_sfx.stream = s
		_sfx.play()
	_wheel.queue_redraw()


func _layout() -> void:
	var c := _root.get_viewport_rect().size * 0.5
	var n := _items.size()
	for i in n:
		var a := -PI * 0.5 + TAU * (i + 0.5) / n
		var r := (RADIUS + INNER) * 0.5
		var slot: Control = _slots[i]
		slot.position = c + Vector2(cos(a), sin(a)) * r - slot.size * 0.5
	_status.position = c - Vector2(200, 30)
	_status.size = Vector2(400, 60)
	_wheel.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("buy"):
		if _open:
			close()
		elif Game.player and Game.player.is_alive() and Game.is_world_ready:
			open()
		get_viewport().set_input_as_handled()
		return
	if not _open:
		return
	if event.is_action_pressed("menu"):
		close()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		_update_sel((event as InputEventMouseMotion).position)
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_update_sel((event as InputEventMouseButton).position)
		if _sel >= 0:
			Game.buy(_items[_sel])
		get_viewport().set_input_as_handled()


func _update_sel(pos: Vector2) -> void:
	var c := _root.get_viewport_rect().size * 0.5
	var d := pos - c
	var old := _sel
	if d.length() < INNER * 0.6:
		_sel = -1
	else:
		var a := fposmod(d.angle() + PI * 0.5, TAU)
		_sel = int(a / TAU * _items.size()) % _items.size()
	if old != _sel:
		_wheel.queue_redraw()


func _process(_delta: float) -> void:
	if not _open:
		return
	var combat := Game.in_combat()
	var txt := "$%d" % Game.money
	if combat:
		txt += "\nCan't buy during combat"
	elif _sel >= 0:
		var id := _items[_sel]
		txt = "%s  $%d\n$%d left" % [Sheets.weapon_row(id).get("display_name", id), Sheets.price(id), Game.money]
	_status.text = txt
	for i in _items.size():
		var slot: Control = _slots[i]
		var ok := Game.money >= Sheets.price(_items[i]) and not combat
		slot.modulate = Color(1, 1, 1, 1) if ok else Color(0.55, 0.55, 0.55, 0.8)


func _draw_wheel() -> void:
	if not _open:
		return
	var c := _wheel.size * 0.5
	var n := _items.size()
	if n == 0:
		return
	for i in n:
		var a0 := -PI * 0.5 + TAU * i / n
		var a1 := -PI * 0.5 + TAU * (i + 1) / n
		var pts := PackedVector2Array()
		var steps := 12
		for k in steps + 1:
			var a := lerpf(a0, a1, float(k) / steps)
			pts.append(c + Vector2(cos(a), sin(a)) * RADIUS)
		for k in range(steps, -1, -1):
			var a := lerpf(a0, a1, float(k) / steps)
			pts.append(c + Vector2(cos(a), sin(a)) * INNER)
		var col := Color(0.08, 0.1, 0.12, 0.82)
		if i == _sel:
			col = Color(0.85, 0.6, 0.15, 0.85)
		_wheel.draw_colored_polygon(pts, col)
		_wheel.draw_line(c + Vector2(cos(a0), sin(a0)) * INNER, c + Vector2(cos(a0), sin(a0)) * RADIUS, Color(1, 1, 1, 0.25), 2.0)
	_wheel.draw_arc(c, RADIUS, 0, TAU, 96, Color(1, 1, 1, 0.35), 2.0)
	_wheel.draw_arc(c, INNER, 0, TAU, 64, Color(1, 1, 1, 0.35), 2.0)
