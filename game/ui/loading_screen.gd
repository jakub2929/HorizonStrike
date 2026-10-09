extends CanvasLayer
## Loading screen with the converter's real progress (stage, done/total) during bootstrap.

const STAGE_NAMES := {"weapons": "Converting CS2 weapons", "machines": "Converting Horizon machines",
	"audio": "Converting Horizon music and sounds", "index": "Reading the world index",
	"start-area": "Converting the area around Mother's Heart", "cell": "Building the world", "start": "Starting the converter"}
## Rough share of each bootstrap stage in the total bar.
const STAGE_WEIGHT := {"start": [0.0, 0.03], "weapons": [0.03, 0.35], "machines": [0.35, 0.55], "audio": [0.55, 0.65],
	"index": [0.65, 0.7], "start-area": [0.7, 0.95], "cell": [0.95, 1.0]}

var _title: Label
var _stage: Label
var _detail: Label
var _bar: ProgressBar
var _t0 := 0.0


func _ready() -> void:
	layer = 20
	_t0 = Time.get_ticks_msec() / 1000.0
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.08)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-420, -120)
	box.size = Vector2(840, 240)
	box.add_theme_constant_override("separation", 16)
	add_child(box)
	_title = Label.new()
	_title.text = "HORIZON STRIKE"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 48)
	_title.add_theme_color_override("font_color", Color(0.95, 0.65, 0.25))
	box.add_child(_title)
	_stage = Label.new()
	_stage.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stage.add_theme_font_size_override("font_size", 22)
	box.add_child(_stage)
	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.custom_minimum_size = Vector2(840, 26)
	box.add_child(_bar)
	_detail = Label.new()
	_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.add_theme_font_size_override("font_size", 15)
	_detail.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	box.add_child(_detail)
	set_stage("start", 0, 1)


func set_stage(stage: String, done: int, total: int) -> void:
	_stage.text = "%s  (%d/%d)" % [STAGE_NAMES.get(stage, stage.capitalize()), done, total] if total > 1 else str(STAGE_NAMES.get(stage, stage.capitalize()))
	var w: Array = STAGE_WEIGHT.get(stage, [0.0, 1.0])
	var f := float(done) / maxf(float(total), 1.0)
	_bar.value = maxf(_bar.value, lerpf(float(w[0]), float(w[1]), f))


func set_detail(text: String) -> void:
	_detail.text = text


func _process(_delta: float) -> void:
	_title.text = "HORIZON STRIKE  %ds" % int(Time.get_ticks_msec() / 1000.0 - _t0)
