extends "res://autotest/scenarios/r01_shots.gd"
## r09shot (child of r09, preset from --gfx-preset): r01's pose shots (teleport + aim as setup, Game.screenshot) saved
## as <pose>_<preset>.png in this child's --out.


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var gs: Node = ctx.tree.root.get_node_or_null("GraphicsSettings")
	if not api_check(ctx.missing_api(g, ["player"], ["teleport", "aim_at", "screenshot"]) + ([] if gs != null else ["GraphicsSettings autoload"])):
		return false
	var preset := str(gs.get("preset"))
	data.preset = preset
	data.graphics = gs.call("describe")
	check("preset from --gfx-preset active", preset in ["low", "medium", "high"], preset)
	var poses: Variant = ctx.oracle.system("perf.shot_poses")
	if not check("perf.shot_poses filled (systems sheet)", poses is Dictionary and not (poses as Dictionary).is_empty(), str(poses)):
		return false
	ctx.player.set("invulnerable", true)
	var shots := {}
	for name in (poses as Dictionary):
		shots[name] = await _shot(ctx, g, "%s_%s" % [name, preset], poses[name])
	data.shots = shots
	return true
