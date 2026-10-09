extends CanvasLayer
## HUD: money, health, armor, ammo, weapon, cache size (ui.show_cache_size), crosshair, hit marker, messages,
## damage flash and the death overlay. English UI (D9).

const Sheets := preload("res://core/sheets.gd")

var _money: Label
var _hp: Label
var _armor: Label
var _ammo: Label
var _weapon: Label
var _cache: Label
var _msg: Label
var _center: Label
var _flash: ColorRect
var _cross: Control
var _hit_t := 0.0
var _hit_weak := false
var _msg_t := 0.0
var _flash_a := 0.0
var _cache_timer := 0.0
var _death_t := -1.0


func _ready() -> void:
	layer = 5
	_flash = ColorRect.new()
	_flash.color = Color(0.8, 0.0, 0.0, 0.0)
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_flash)
	_money = _label(Vector2(24, 20), 30, Color(0.55, 0.95, 0.45))
	_cache = _label(Vector2(-24, 20), 16, Color(0.85, 0.85, 0.85), true)
	_hp = _label(Vector2(24, -60), 34, Color(0.95, 0.95, 0.9), false, true)
	_armor = _label(Vector2(190, -60), 34, Color(0.65, 0.8, 1.0), false, true)
	_ammo = _label(Vector2(-24, -60), 34, Color(0.95, 0.95, 0.9), true, true)
	_weapon = _label(Vector2(-24, -100), 18, Color(0.85, 0.85, 0.85), true, true)
	_msg = Label.new()
	_msg.add_theme_font_size_override("font_size", 22)
	_msg.add_theme_color_override("font_color", Color(1, 0.95, 0.7))
	_msg.add_theme_color_override("font_outline_color", Color.BLACK)
	_msg.add_theme_constant_override("outline_size", 6)
	_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_msg.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_msg.position = Vector2(-400, -170)
	_msg.size = Vector2(800, 40)
	add_child(_msg)
	_center = Label.new()
	_center.add_theme_font_size_override("font_size", 40)
	_center.add_theme_color_override("font_outline_color", Color.BLACK)
	_center.add_theme_constant_override("outline_size", 8)
	_center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center.set_anchors_preset(Control.PRESET_CENTER)
	_center.position = Vector2(-500, -140)
	_center.size = Vector2(1000, 120)
	add_child(_center)
	_cross = Control.new()
	_cross.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cross.draw.connect(_draw_cross)
	add_child(_cross)
	Game.hud_message.connect(message)
	Game.money_changed.connect(func(_v): _refresh())


func _label(pos: Vector2, size: int, color: Color, right: bool = false, bottom: bool = false) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 6)
	var preset := Control.PRESET_TOP_LEFT
	if right and bottom:
		preset = Control.PRESET_BOTTOM_RIGHT
	elif right:
		preset = Control.PRESET_TOP_RIGHT
	elif bottom:
		preset = Control.PRESET_BOTTOM_LEFT
	l.set_anchors_preset(preset)
	if right:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		l.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		l.position = Vector2(pos.x - 400, pos.y)
		l.size = Vector2(400, size + 10)
	else:
		l.position = pos
		l.size = Vector2(400, size + 10)
	if bottom:
		l.grow_vertical = Control.GROW_DIRECTION_BEGIN
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


func message(text: String) -> void:
	if text == "":
		return
	_msg.text = text
	_msg_t = 3.0


func hitmarker(weak: bool) -> void:
	_hit_t = 0.25
	_hit_weak = weak
	_cross.queue_redraw()


func flash_damage() -> void:
	_flash_a = 0.35


func show_death(seconds: float) -> void:
	_death_t = seconds


func hide_death() -> void:
	_death_t = -1.0
	_center.text = ""


func _refresh() -> void:
	_money.text = "$%d" % Game.money


func _process(delta: float) -> void:
	_refresh()
	var p: Node3D = Game.player
	if p:
		_hp.text = "+ %d" % ceili(p.health)
		_armor.text = "◈ %d" % ceili(p.armor)
		var id: String = p.current_weapon
		var row := Sheets.weapon_row(id)
		_weapon.text = str(row.get("display_name", id))
		var a: Vector2i = p.ammo(id)
		var cat := str(row.get("category", ""))
		if cat == "knife" or cat == "equipment":
			_ammo.text = ""
		elif cat == "grenade":
			_ammo.text = "x%d" % a.x
		else:
			_ammo.text = "%d / %d" % [a.x, a.y]
	_cache_timer -= delta
	if _cache_timer <= 0.0 and Sheets.sys_bool("ui.show_cache_size", true):
		_cache_timer = 1.0
		_cache.text = "Cache %s / %s" % [human_bytes(Game.cache_bytes()), human_bytes(Game.cache_cap_bytes)]
	if _msg_t > 0.0:
		_msg_t -= delta
		_msg.modulate.a = clampf(_msg_t, 0.0, 1.0)
	if _flash_a > 0.0:
		_flash_a = maxf(_flash_a - delta * 1.2, 0.0)
	_flash.color.a = _flash_a
	if _hit_t > 0.0:
		_hit_t -= delta
		_cross.queue_redraw()
	if _death_t >= 0.0:
		_death_t = maxf(_death_t - delta, 0.0)
		_center.text = "You died\nRespawning at the campfire in %d" % ceili(_death_t)


func _draw_cross() -> void:
	var c := _cross.size * 0.5
	var col := Color(0.3, 1.0, 0.3, 0.9)
	var gap := 4.0
	var ln := 9.0
	for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		_cross.draw_line(c + d * gap, c + d * (gap + ln), Color(0, 0, 0, 0.6), 4.0)
		_cross.draw_line(c + d * gap, c + d * (gap + ln), col, 2.0)
	if _hit_t > 0.0:
		var hc := Color(1.0, 0.25, 0.2) if _hit_weak else Color(1, 1, 1)
		for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			_cross.draw_line(c + d * 6.0, c + d * 14.0, hc, 2.5)


static func human_bytes(b: int) -> String:
	if b <= 0:
		return "0 B"
	var units := ["B", "KB", "MB", "GB", "TB"]
	var v := float(b)
	var i := 0
	while v >= 1024.0 and i < units.size() - 1:
		v /= 1024.0
		i += 1
	return ("%.0f %s" if i == 0 else "%.1f %s") % [v, units[i]]
