extends "res://autotest/lib/scenario.gd"
## t26a (child A of t26): Esc > Graphics by input, then a click on each preset button in turn (the first differs from
## the current preset, the last one stays for the restart in t26b). After every click the engine state must equal the
## sheet's preset within 2 frames, the clicked button shows pressed and graphics.json in --user-dir holds the preset.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const GfxState := preload("res://autotest/lib/gfxstate.gd")


func _init() -> void:
	timeout_s = 600.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var gs: Node = ctx.tree.root.get_node_or_null("GraphicsSettings")
	if not api_check([] if gs != null else ["GraphicsSettings autoload"]):
		return false
	var gfile: String = gs.call("settings_path")
	data.settings_file = gfile
	await ctx.wait(2.0)   # the start cells' vegetation chunks are tracked
	var before := str(gs.get("preset"))
	data.preset_before = before
	data.state_before = GfxState.engine_state(ctx)
	var seq := ["low", "medium", "high", "low"] if before != "low" else ["high", "medium", "low", "high"]
	var inp = InputSim.new(ctx)
	check("Esc > Graphics opens by input", await GfxState.open_graphics(ctx, inp), str(inp.sent.slice(-4)))
	var steps := []
	for p in seq:
		var btn := "Preset" + str(p).capitalize()
		var f0 := Engine.get_process_frames()
		var clicked: bool = await GfxState.click_control(ctx, inp, btn)
		# InputSim.click waits 2 frames after the press and 2 after the release; the state is read right after
		var st := GfxState.engine_state(ctx)
		var cmp: Array = GfxState.compare(ctx, p, st)
		var frames_after_release := 2
		var b := GfxState.control(ctx, btn) as BaseButton
		var pressed := b != null and b.button_pressed
		var in_file := GfxState.file_preset(gfile)
		steps.append({"preset": p, "clicked": clicked, "frames_click_to_check": Engine.get_process_frames() - f0,
			"state": st, "mismatches": cmp[1], "button_pressed": pressed, "file": in_file, "settings_preset": str(gs.get("preset"))})
		check("click %s: engine state = graphics.presets.%s within %d frames of the release" % [btn, p, frames_after_release], clicked and cmp[0], "; ".join(cmp[1]) if not cmp[0] else "")
		check("click %s: button pressed, graphics.json preset %s" % [btn, p], pressed and in_file == p, "pressed %s, file %s" % [str(pressed), in_file])
		await ctx.wait(1.0)
	data.steps = steps
	data.final_preset = seq[seq.size() - 1]
	check("Back + Esc close the menu (game runs)", await GfxState.close_graphics(ctx, inp), str(inp.sent.slice(-4)))
	data.input = inp.sent
	return true
