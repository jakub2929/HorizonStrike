extends RefCounted
## Gait patterns for the procedural machine animation. A leg's cycle phase p runs 0..1: the foot touches down at
## p = 0, stays planted while p < duty and swings for the rest of the cycle. `offsets` are the touchdown phases per
## leg group (fl/fr/bl/br for quadrupeds, l/r for bipeds; groups come from the bind-pose geometry, never from names).
## Footfall orders follow real animals: lateral-sequence walk, diagonal trot, 3-beat canter (lope), transverse
## gallop, half-bound (canids/felids); bob/rock/flex are body motions per gait (fractions of hip height / radians).

const TABLE := {
	"biped_walk": {"offsets": {"l": 0.0, "r": 0.5}, "duty": 0.62, "bob": 0.018, "bob_per_cycle": 2, "rock": 0.0, "flex": 0.0, "lift": 1.0},
	"biped_run": {"offsets": {"l": 0.0, "r": 0.5}, "duty": 0.40, "bob": 0.035, "bob_per_cycle": 2, "rock": 0.03, "flex": 0.0, "lift": 1.25},
	"walk": {"offsets": {"bl": 0.0, "fl": 0.25, "br": 0.5, "fr": 0.75}, "duty": 0.68, "bob": 0.012, "bob_per_cycle": 2, "rock": 0.0, "flex": 0.0, "lift": 1.0},
	"trot": {"offsets": {"fl": 0.0, "br": 0.0, "fr": 0.5, "bl": 0.5}, "duty": 0.5, "bob": 0.025, "bob_per_cycle": 2, "rock": 0.0, "flex": 0.0, "lift": 1.15},
	"lope": {"offsets": {"bl": 0.0, "br": 0.3, "fl": 0.3, "fr": 0.6}, "duty": 0.42, "bob": 0.03, "bob_per_cycle": 1, "rock": 0.05, "flex": 0.04, "lift": 1.2},
	"gallop": {"offsets": {"bl": 0.0, "br": 0.1, "fl": 0.45, "fr": 0.55}, "duty": 0.36, "bob": 0.035, "bob_per_cycle": 1, "rock": 0.06, "flex": 0.05, "lift": 1.3},
	"bound": {"offsets": {"bl": 0.0, "br": 0.05, "fl": 0.5, "fr": 0.55}, "duty": 0.33, "bob": 0.04, "bob_per_cycle": 1, "rock": 0.08, "flex": 0.1, "lift": 1.3},
}


## Gait for a speed. `run_gait` is the sheet value (anim.run_gait): biped_run, gallop, trot_gallop, bound, lope;
## below ~1.35x walk speed every machine walks; two-gait run profiles trot first.
static func select(run_gait: String, biped: bool, speed: float, walk_speed: float, run_speed: float, current: String) -> String:
	var walk_id := "biped_walk" if biped else "walk"
	var hyst := 0.1 * walk_speed
	var to_run := maxf(walk_speed * 1.35, 0.6)
	var limit := to_run + (hyst if current == walk_id else -hyst)
	if speed < limit:
		return walk_id
	if biped:
		return "biped_run"
	match run_gait:
		"trot_gallop", "lope", "bound":
			var fast := run_gait if run_gait != "trot_gallop" else "gallop"
			var switch := run_speed * (0.6 if run_gait == "trot_gallop" else 0.5)
			var lim2 := switch + (hyst if current == "trot" else -hyst)
			return "trot" if speed < lim2 else fast
		"gallop", "trot":
			return run_gait
	return run_gait if TABLE.has(run_gait) else "gallop"


static func params(id: String) -> Dictionary:
	return TABLE.get(id, TABLE["walk"])


## Touchdown phase of a leg group in a gait; groups missing from the gait (e.g. a 6-legged rig) use the nearest one.
static func offset(id: String, group: String) -> float:
	var offs: Dictionary = params(id)["offsets"]
	if offs.has(group):
		return float(offs[group])
	if group.length() == 2 and offs.has(group.substr(1)):
		return float(offs[group.substr(1)])
	if group.length() == 1:
		for g in offs:
			if str(g).ends_with(group):
				return float(offs[g])
	return 0.0
