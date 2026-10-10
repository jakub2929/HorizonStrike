extends Control
## Player-side hit effects (0.3 H4), all numbers from the systems rows fx.*:
## - Hitmarker: crosshair marker on every hit of a machine, normal / weak style (fx.hitmarker, longer on a kill);
## - DamageNumbers: the dealt damage at the hit point, rising (fx.damage_number; off with settings.json
##   show_damage_numbers, Esc menu toggle);
## - DamageIndicator: screen-edge arc towards the source of damage the player takes (fx.damage_indicator);
## - Vignette: red screen edge from fx.vignette.start_health_frac of the max health down, plus a flash per hit.
## Sounds: audio/feedback_audio.gd (fx.sound_*). Aimpunch lives in player.gd (fx.aimpunch). Game.fx_stats() reads
## the counters here.

const Sheets := preload("res://core/sheets.gd")
const FeedbackAudio := preload("res://audio/feedback_audio.gd")
const SettingsMenu := preload("res://ui/settings_menu.gd")

const VIGNETTE_SHADER := """
shader_type canvas_item;
uniform float alpha = 0.0;
uniform vec4 tint : source_color = vec4(0.75, 0.0, 0.0, 1.0);
void fragment() {
	float r = length(UV - vec2(0.5)) * 1.4142;
	COLOR = vec4(tint.rgb, alpha * smoothstep(0.35, 1.0, r));
}
"""

var audio: Node
var hitmarkers := 0
var numbers := 0
var indicators := 0

var _hitmarker: Control
var _numbers: Control
var _indicator: Control
var _vignette: ColorRect
var _vmat: ShaderMaterial
var _hm_t := 0.0
var _hm_weak := false
var _num: Array = []           # [Label, world pos, age, lifetime, offset]
var _ind: Array = []           # [world source pos, age]
var _flash := 0.0
var _vig_alpha := 0.0
var _last_bearing := 0.0


func _fx(row: String) -> Dictionary:
	var v: Variant = Sheets.sys("fx." + row)
	return v if typeof(v) == TYPE_DICTIONARY else {}


static func _col(v: Variant, fallback: Color) -> Color:
	if v is Array and (v as Array).size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]), float(v[3]) if (v as Array).size() > 3 else 1.0)
	return fallback


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette = ColorRect.new()
	_vignette.name = "Vignette"
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vmat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = VIGNETTE_SHADER
	_vmat.shader = sh
	_vignette.material = _vmat
	add_child(_vignette)
	_indicator = Control.new()
	_indicator.name = "DamageIndicator"
	_indicator.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_indicator.draw.connect(_draw_indicator)
	add_child(_indicator)
	_numbers = Control.new()
	_numbers.name = "DamageNumbers"
	_numbers.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_numbers.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_numbers)
	_hitmarker = Control.new()
	_hitmarker.name = "Hitmarker"
	_hitmarker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hitmarker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hitmarker.draw.connect(_draw_hitmarker)
	add_child(_hitmarker)
	audio = FeedbackAudio.new()
	audio.name = "FeedbackAudio"
	add_child(audio)
	Game.player_hit_machine.connect(_on_hit)
	Game.player_hurt.connect(_on_hurt)


# ------------------------------------------------------------------ dealing damage

func _on_hit(m: Node, dealt: float, weak: bool, hit_pos: Vector3, killed: bool) -> void:
	var hm := _fx("hitmarker")
	var style: Dictionary = hm.get("weak" if weak else "normal", {})
	_hm_t = float(style.get("time_s", 0.2)) + (float(hm.get("kill_extra_time_s", 0.0)) if killed else 0.0)
	_hm_weak = weak
	hitmarkers += 1
	_hitmarker.queue_redraw()
	if SettingsMenu.show_damage_numbers() and dealt > 0.0 and hit_pos != Vector3.INF:
		_spawn_number(dealt, weak, hit_pos)
	var p: Node = Game.player
	var knife: bool = p != null and str(Sheets.weapon_row(str(p.current_weapon)).get("category", "")) == "knife"
	if killed and weak:
		audio.play_row("fx.sound_kill_weak")
	elif knife:
		audio.play_row("fx.sound_hit_knife")
	else:
		audio.play_row("fx.sound_hit_weak" if weak else "fx.sound_hit")


func _spawn_number(dealt: float, weak: bool, pos: Vector3) -> void:
	var dn := _fx("damage_number")
	var l := Label.new()
	l.text = str(int(round(dealt)))
	l.add_theme_font_size_override("font_size", int(dn.get("weak_font_px" if weak else "font_px", 22)))
	l.add_theme_color_override("font_color", _col(dn.get("weak_color" if weak else "color"), Color.WHITE))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 5)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.visible = false
	_numbers.add_child(l)
	var s := float(dn.get("spread_m", 0.0))
	var off := Vector3(randf_range(-s, s), randf_range(-s, s) * 0.5, randf_range(-s, s))
	_num.append([l, pos, 0.0, float(dn.get("lifetime_s", 0.8)), off])
	numbers += 1


# ------------------------------------------------------------------ taking damage

func _on_hurt(amount: float, source_pos: Vector3, armored: bool) -> void:
	var vg := _fx("vignette")
	_flash = float(vg.get("hit_flash_s", 0.3))
	if source_pos != Vector3.INF:
		_ind.append([source_pos, 0.0])
		indicators += 1
		if _ind.size() > 8:
			_ind.pop_front()
	if amount > 0.0:
		audio.play_row("fx.sound_hurt_armor" if armored else "fx.sound_hurt")


func _process(delta: float) -> void:
	var p: Node3D = Game.player
	var cam: Camera3D = p.camera if p else null
	# hitmarker
	if _hm_t > 0.0:
		_hm_t -= delta
		_hitmarker.queue_redraw()
	# damage numbers
	var rise := float(_fx("damage_number").get("rise_m", 0.6))
	for e in _num.duplicate():
		e[2] = float(e[2]) + delta
		var l: Label = e[0]
		var k := float(e[2]) / maxf(float(e[3]), 0.01)
		if k >= 1.0 or cam == null:
			_num.erase(e)
			l.queue_free()
			continue
		var wp: Vector3 = (e[1] as Vector3) + (e[4] as Vector3) + Vector3.UP * rise * k
		if cam.is_position_behind(wp):
			l.visible = false
			continue
		var sp := cam.unproject_position(wp)
		l.visible = true
		l.position = sp - l.size * 0.5
		l.modulate.a = clampf((1.0 - k) * 3.0, 0.0, 1.0)
	# damage indicator
	var di := _fx("damage_indicator")
	var life := float(di.get("time_s", 1.5))
	for e in _ind.duplicate():
		e[1] = float(e[1]) + delta
		if float(e[1]) >= life:
			_ind.erase(e)
	_indicator.queue_redraw()
	# vignette
	var vg := _fx("vignette")
	var frac := 1.0
	if p and p.get("health") != null:
		frac = clampf(float(p.health) / maxf(Game.max_health(), 1.0), 0.0, 1.0)
	var start := float(vg.get("start_health_frac", 0.6))
	var base := float(vg.get("max_alpha", 0.55)) * pow(clampf((start - frac) / maxf(start, 0.001), 0.0, 1.0), float(vg.get("gamma", 1.5)))
	if p and not p.is_alive():
		base = 0.0
	var flash_s := float(vg.get("hit_flash_s", 0.3))
	if _flash > 0.0:
		_flash = maxf(_flash - delta, 0.0)
	_vig_alpha = clampf(base + float(vg.get("hit_flash_alpha", 0.25)) * (_flash / maxf(flash_s, 0.001)), 0.0, 1.0)
	_vmat.set_shader_parameter("alpha", _vig_alpha)


## Bearing of a world point from the view: 0 = straight ahead, positive = to the right (radians).
func _bearing(src: Vector3) -> float:
	var p: Node3D = Game.player
	if p == null:
		return 0.0
	var cam: Camera3D = p.camera
	var local := cam.global_transform.basis.inverse() * (src - cam.global_position)
	return atan2(local.x, -local.z)


func _draw_indicator() -> void:
	if _ind.is_empty():
		return
	var di := _fx("damage_indicator")
	var life := float(di.get("time_s", 1.5))
	var fade := float(di.get("fade_s", 0.5))
	var arc := deg_to_rad(float(di.get("arc_deg", 40.0)))
	var col := _col(di.get("color"), Color(1, 0.15, 0.1, 0.85))
	var c := _indicator.size * 0.5
	var r := minf(_indicator.size.x, _indicator.size.y) * 0.32
	for e in _ind:
		var b := _bearing(e[0])
		_last_bearing = b
		var a := col
		a.a *= clampf((life - float(e[1])) / maxf(fade, 0.001), 0.0, 1.0)
		var mid := -PI * 0.5 + b
		_indicator.draw_arc(c, r, mid - arc * 0.5, mid + arc * 0.5, 24, a, 9.0, true)


func _draw_hitmarker() -> void:
	if _hm_t <= 0.0:
		return
	var style: Dictionary = _fx("hitmarker").get("weak" if _hm_weak else "normal", {})
	var col := _col(style.get("color"), Color.WHITE)
	var size := float(style.get("size_px", 14))
	var c := _hitmarker.size * 0.5
	for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		var dn: Vector2 = d.normalized()
		_hitmarker.draw_line(c + dn * size * 0.4, c + dn * size, Color(0, 0, 0, 0.6 * col.a), 4.5)
		_hitmarker.draw_line(c + dn * size * 0.4, c + dn * size, col, 2.5)


## Counters and current state for Game.fx_stats().
func stats() -> Dictionary:
	return {"hitmarkers": hitmarkers, "hitmarker_visible": _hm_t > 0.0, "hitmarker_style": "weak" if _hm_weak else "normal",
		"numbers": numbers, "numbers_active": _num.size(), "indicators": indicators, "indicator_visible": not _ind.is_empty(),
		"indicator_bearing_deg": rad_to_deg(_bearing(_ind[-1][0])) if not _ind.is_empty() else 0.0,
		"vignette_alpha": _vig_alpha, "sounds": audio.played, "last_sound": audio.last, "hurt_sound_playing": audio.hurt_playing()}
