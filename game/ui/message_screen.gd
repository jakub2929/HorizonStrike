extends CanvasLayer
## Full-screen message: the MissingHzdScreen (node named "MissingHzdScreen" with a Label holding
## systems ui.missing_hzd_message) and the error screen (message + path of the log).

var panel: Control
var label: Label


static func make(node_name: String, title: String, text: String, detail: String) -> CanvasLayer:
	var s: CanvasLayer = load("res://ui/message_screen.gd").new()
	s.layer = 30
	s.name = node_name + "Layer"
	var root := Control.new()
	root.name = node_name
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	s.add_child(root)
	s.panel = root
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-450, -160)
	box.size = Vector2(900, 320)
	box.add_theme_constant_override("separation", 20)
	root.add_child(box)
	var t := Label.new()
	t.text = title
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 40)
	t.add_theme_color_override("font_color", Color(0.95, 0.65, 0.25))
	box.add_child(t)
	var l := Label.new()
	l.name = "Label"
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(900, 0)
	l.add_theme_font_size_override("font_size", 24)
	box.add_child(l)
	s.label = l
	if detail != "":
		var d := Label.new()
		d.name = "Detail"
		d.text = detail
		d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.custom_minimum_size = Vector2(900, 0)
		d.add_theme_font_size_override("font_size", 16)
		d.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		box.add_child(d)
	var b := Button.new()
	b.text = "Quit"
	b.custom_minimum_size = Vector2(200, 44)
	b.pressed.connect(func(): s.get_tree().quit(0))
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_child(b)
	box.add_child(hb)
	return s
