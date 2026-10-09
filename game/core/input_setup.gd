extends RefCounted
## CS-style default bindings, registered at runtime (no input map in project.godot).

const KEYS := {
	"move_forward": [KEY_W], "move_back": [KEY_S], "move_left": [KEY_A], "move_right": [KEY_D],
	"jump": [KEY_SPACE], "crouch": [KEY_CTRL, KEY_C], "walk": [KEY_SHIFT], "reload": [KEY_R], "buy": [KEY_B],
	"slot1": [KEY_1], "slot2": [KEY_2], "slot3": [KEY_3], "slot4": [KEY_4], "inspect": [KEY_F], "use": [KEY_E],
	"menu": [KEY_ESCAPE], "drop_last": [KEY_Q],
}
const MOUSE := {"fire": [MOUSE_BUTTON_LEFT], "alt_fire": [MOUSE_BUTTON_RIGHT],
	"next_weapon": [MOUSE_BUTTON_WHEEL_DOWN], "prev_weapon": [MOUSE_BUTTON_WHEEL_UP]}


static func setup() -> void:
	for action in KEYS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for k in KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(action, ev)
	for action in MOUSE:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for b in MOUSE[action]:
			var ev := InputEventMouseButton.new()
			ev.button_index = b
			InputMap.action_add_event(action, ev)
