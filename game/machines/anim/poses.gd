extends RefCounted
## Pose library for the procedural machine animation: attack poses (machine_attacks.pose), hit reactions
## (machines.anim.hit_react) and idle actions (machines.anim.idle_actions). A pose is a set of channel targets for
## the end of its wind-up ("windup") and for its strike ("active"); the animator adds the sampled channels to the
## locomotion pose before the leg IK runs, so planted feet stay planted.
## Channels (radians; body_dy as a fraction of hip height, body_dz of body length):
##   body_pitch (+ nose up), body_roll (+ right side down), body_yaw (+ left), body_dy (+ up), body_dz (+ forward),
##   neck_pitch (+ down), neck_yaw (+ left), neck_roll, head_pitch (+ down), head_yaw (+ left), tail_yaw, tail_pitch
##   (+ up), jaw (0..1 open), rotor (0..1 spin), front_lift (0..1 front feet off the ground, body pivots on the hind
##   legs), rear_kick (0..1 hind feet kick back), paw (0..1 one front foot scrapes), air (0..1 all feet off the ground)
## "osc" adds oscillations [{ch, amp, hz}] under a sin(pi t) envelope (idle actions, head shakes).

const ATTACKS := {
	"lunge_bite": {"windup": {"body_dz": -0.05, "body_dy": -0.06, "neck_pitch": -0.3, "head_pitch": -0.15, "jaw": 0.6},
		"active": {"body_dz": 0.12, "body_dy": -0.03, "neck_pitch": 0.3, "head_pitch": 0.15, "jaw": 0.0}},
	"tail_sweep": {"windup": {"tail_yaw": -1.0, "body_yaw": 0.25, "neck_yaw": 0.3, "body_dy": -0.04},
		"active": {"tail_yaw": 1.6, "body_yaw": -0.45, "neck_yaw": -0.25}},
	"eye_charge": {"windup": {"neck_pitch": -0.25, "head_pitch": -0.2, "body_dy": -0.05, "body_pitch": 0.05},
		"active": {"head_pitch": 0.12, "neck_pitch": -0.1, "body_dz": -0.04}},
	"rear_kick": {"windup": {"body_pitch": -0.12, "body_dy": -0.05, "neck_pitch": 0.3},
		"active": {"rear_kick": 1.0, "body_pitch": -0.18, "neck_pitch": 0.35}},
	"charge": {"windup": {"body_dy": -0.08, "neck_pitch": 0.45, "head_pitch": 0.1, "paw": 1.0, "body_pitch": -0.04},
		"active": {"neck_pitch": 0.35, "body_pitch": -0.05, "body_dy": -0.04}},
	"ram": {"windup": {"neck_pitch": 0.5, "body_dy": -0.06, "paw": 1.0, "rotor": 1.0},
		"active": {"neck_pitch": 0.4, "body_pitch": -0.06, "rotor": 1.0}},
	"rotor_sweep": {"windup": {"neck_pitch": 0.35, "neck_yaw": -0.6, "rotor": 1.0, "body_dy": -0.04},
		"active": {"neck_pitch": 0.4, "neck_yaw": 0.7, "rotor": 1.0, "body_yaw": -0.15}},
	"pounce": {"windup": {"body_dy": -0.2, "body_pitch": 0.06, "neck_pitch": 0.2, "body_dz": -0.05},
		"active": {"air": 1.0, "body_dy": 0.18, "body_pitch": -0.1, "neck_pitch": 0.1, "jaw": 0.6}},
	"laser_aim": {"windup": {"body_dy": -0.07, "neck_pitch": -0.3, "head_pitch": -0.1, "body_pitch": 0.04, "jaw": 0.3},
		"active": {"neck_pitch": -0.3, "head_pitch": -0.05, "jaw": 0.3}, "osc": [{"ch": "head_pitch", "amp": 0.04, "hz": 11.0}]},
	"lunge": {"windup": {"body_dy": -0.12, "neck_pitch": 0.1, "body_dz": -0.04},
		"active": {"air": 1.0, "body_dy": 0.08, "body_dz": 0.1, "neck_pitch": 0.2, "jaw": 0.5}},
	"headbutt": {"windup": {"neck_pitch": -0.5, "head_pitch": -0.2, "body_dz": -0.06, "body_dy": -0.03},
		"active": {"neck_pitch": 0.55, "head_pitch": 0.2, "body_dz": 0.1}},
	"stomp": {"windup": {"front_lift": 1.0, "body_pitch": 0.35, "neck_pitch": -0.3},
		"active": {"front_lift": 0.0, "body_pitch": -0.04, "body_dy": -0.05, "neck_pitch": 0.2}},
}

## Hit reactions: short additive twitches (side-dependent channels are mirrored by the animator).
const HITS := {
	"flinch_back": {"windup": {}, "active": {"body_dz": -0.05, "neck_pitch": -0.25, "head_pitch": -0.1, "body_pitch": 0.05}},
	"flinch_side": {"windup": {}, "active": {"body_roll": 0.12, "neck_yaw": 0.3, "body_dy": -0.03, "head_yaw": 0.15}},
	"rear_up": {"windup": {"neck_pitch": -0.2}, "active": {"front_lift": 1.0, "body_pitch": 0.3, "neck_pitch": -0.35}},
}

## Idle actions (calm, standing): duration + held channels + oscillations.
const IDLES := {
	"scan": {"dur": 4.5, "hold": {"neck_pitch": -0.05}, "osc": [{"ch": "head_yaw", "amp": 0.7, "hz": 0.22}]},
	"look_around": {"dur": 3.0, "hold": {"neck_pitch": -0.12}, "osc": [{"ch": "head_yaw", "amp": 0.6, "hz": 0.33}]},
	"head_shake": {"dur": 0.9, "hold": {}, "osc": [{"ch": "neck_roll", "amp": 0.3, "hz": 4.0}]},
	"sniff": {"dur": 2.5, "hold": {"neck_pitch": 0.6, "head_pitch": 0.2}, "osc": [{"ch": "head_pitch", "amp": 0.08, "hz": 3.0}]},
	"itch": {"dur": 2.0, "hold": {"neck_yaw": 0.9, "neck_pitch": 0.3, "head_yaw": 0.4}, "osc": [{"ch": "head_pitch", "amp": 0.1, "hz": 4.0}]},
	"shake": {"dur": 1.0, "hold": {}, "osc": [{"ch": "body_roll", "amp": 0.08, "hz": 5.0}, {"ch": "neck_roll", "amp": 0.25, "hz": 5.0}]},
	"stretch": {"dur": 2.5, "hold": {"body_pitch": -0.12, "body_dz": -0.06, "neck_pitch": 0.3, "body_dy": -0.06}},
	"howl": {"dur": 3.0, "hold": {"neck_pitch": -0.7, "head_pitch": -0.3, "jaw": 0.4}},
	"rotor_spin": {"dur": 3.0, "hold": {"rotor": 1.0}},
	"snort": {"dur": 0.8, "hold": {"head_pitch": 0.2}, "osc": [{"ch": "neck_pitch", "amp": 0.12, "hz": 3.0}]},
}


static func has_attack(pose: String) -> bool:
	return ATTACKS.has(pose)


static func idle_duration(id: String) -> float:
	return float(IDLES.get(id, {}).get("dur", 0.0))


## Channels of a timed pose at time t (s): wind-up eases into the "windup" targets, the strike reaches the "active"
## targets fast (35 % of the active time, at most 0.15 s) and holds them, the recovery eases back to neutral.
## Returns {} when the pose is over.
static func sample(def: Dictionary, t: float, windup: float, active: float, recover: float) -> Dictionary:
	var out := {}
	var w: Dictionary = def.get("windup", {})
	var a: Dictionary = def.get("active", {})
	var total := windup + active + recover
	if t >= total or def.is_empty():
		return out
	var keys := {}
	for k in w:
		keys[k] = true
	for k in a:
		keys[k] = true
	if t < windup:
		var s := _smooth(t / maxf(windup, 0.001))
		for k in keys:
			out[k] = float(w.get(k, 0.0)) * s
	elif t < windup + active:
		var s2 := clampf((t - windup) / maxf(minf(active * 0.35, 0.15), 0.01), 0.0, 1.0)
		s2 = 1.0 - (1.0 - s2) * (1.0 - s2)
		for k in keys:
			out[k] = lerpf(float(w.get(k, 0.0)), float(a.get(k, 0.0)), s2)
	else:
		var s3 := _smooth((t - windup - active) / maxf(recover, 0.001))
		for k in keys:
			out[k] = float(a.get(k, 0.0)) * (1.0 - s3)
	_add_osc(def, out, t, total)
	out["_active"] = 1.0 if t >= windup and t < windup + active else 0.0
	return out


## Idle action channels at time t (s), {} when over.
static func sample_idle(id: String, t: float) -> Dictionary:
	var def: Dictionary = IDLES.get(id, {})
	var dur := float(def.get("dur", 0.0))
	var out := {}
	if def.is_empty() or t >= dur:
		return out
	var env := _smooth(clampf(t / 0.4, 0.0, 1.0)) * _smooth(clampf((dur - t) / 0.4, 0.0, 1.0))
	var hold: Dictionary = def.get("hold", {})
	for k in hold:
		out[k] = float(hold[k]) * env
	_add_osc(def, out, t, dur)
	return out


static func _add_osc(def: Dictionary, out: Dictionary, t: float, total: float) -> void:
	for o in def.get("osc", []):
		var env := sin(PI * clampf(t / maxf(total, 0.001), 0.0, 1.0))
		var ch := str(o["ch"])
		out[ch] = float(out.get(ch, 0.0)) + float(o["amp"]) * env * sin(TAU * float(o["hz"]) * t)


static func _smooth(x: float) -> float:
	var c := clampf(x, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)
