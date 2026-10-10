extends CanvasLayer
## Upgrades (0.3): key K (action "upgrades") or the Esc menu entry. Level, XP, points and the three upgrades of the
## systems sheet (upgrades.damage, upgrades.max_health, upgrades.bhop) with one "+" button each; a point buys a level
## (core/progression.gd, saved in progression.json). Pauses the game while open; Esc or K closes it.
## Node names for tests (real input only): UpgradesMenu, UpgradesLevel, UpgradesPoints, Upgrade_<kind> (Button),
## UpgradeLabel_<kind>, UpgradesClose.

const Sheets := preload("res://core/sheets.gd")
const Progression := preload("res://core/progression.gd")

var _root: Control
var _level: Label
var _points: Label
var _labels := {}
var _buttons := {}
var _open := false


func _ready() -> void:
	layer = 26
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.name = "UpgradesMenu"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-320, -220)
	box.size = Vector2(640, 440)
	box.add_theme_constant_override("separation", 14)
	_root.add_child(box)
	var t := Label.new()
	t.text = "Upgrades"
	t.add_theme_font_size_override("font_size", 36)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(t)
	_level = Label.new()
	_level.name = "UpgradesLevel"
	_level.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_level)
	_points = Label.new()
	_points.name = "UpgradesPoints"
	_points.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_points.add_theme_font_size_override("font_size", 22)
	box.add_child(_points)
	for kind in Progression.KINDS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		box.add_child(row)
		var l := Label.new()
		l.name = "UpgradeLabel_" + kind
		l.custom_minimum_size = Vector2(520, 0)
		row.add_child(l)
		var b := Button.new()
		b.name = "Upgrade_" + kind
		b.text = "+"
		b.custom_minimum_size = Vector2(80, 40)
		b.pressed.connect(_on_buy.bind(kind))
		row.add_child(b)
		_labels[kind] = l
		_buttons[kind] = b
	var close_b := Button.new()
	close_b.name = "UpgradesClose"
	close_b.text = "Close"
	close_b.pressed.connect(close)
	box.add_child(close_b)
	Game.progression_changed.connect(_refresh)


func is_open() -> bool:
	return _open


func open() -> void:
	_open = true
	_root.visible = true
	_refresh()
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	_open = false
	_root.visible = false
	get_tree().paused = false
	if Game.main and Game.main.has_method("capture_mouse"):
		Game.main.capture_mouse()


func _on_buy(kind: String) -> void:
	Game.buy_upgrade(kind)
	_refresh()


func _refresh() -> void:
	if not _open:
		return
	var p := Progression.snapshot()
	var lp := Progression.level_progress()
	_level.text = "Level %d / %d   XP %d   (%d / %d to the next level)" % [int(p["level"]), Progression.max_level(), int(p["xp"]), lp.x, lp.y]
	_points.text = "Points: %d" % int(p["points"])
	for kind in Progression.KINDS:
		var lvl := Progression.upgrade_level(kind)
		var row: Dictionary = Sheets.sys("upgrades." + kind) if typeof(Sheets.sys("upgrades." + kind)) == TYPE_DICTIONARY else {}
		var what := ""
		match kind:
			"damage":
				what = "Damage +%d %% per level (now +%d %%)" % [int(row.get("pct_per_level", 0)), int(row.get("pct_per_level", 0)) * lvl]
			"max_health":
				what = "Max health +%d per level (now %d)" % [int(row.get("hp_per_level", 0)), int(Progression.max_health())]
			"bhop":
				what = "Bunny hop: %d jump(s) in a row keep speed" % Progression.bhop_jumps()
		_labels[kind].text = "%s   [%d / %d]" % [what, lvl, Progression.max_upgrade(kind)]
		var why := Progression.can_upgrade(kind)
		(_buttons[kind] as Button).disabled = why != ""
		(_buttons[kind] as Button).tooltip_text = why


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("upgrades"):
		if _open:
			close()
		elif Game.is_world_ready and not get_tree().paused and (Game.buy_wheel == null or not Game.buy_wheel.is_open()):
			open()
		get_viewport().set_input_as_handled()
	elif _open and event.is_action_pressed("menu"):
		close()
		get_viewport().set_input_as_handled()
