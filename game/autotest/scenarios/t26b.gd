extends "res://autotest/lib/scenario.gd"
## t26b (child B of t26, same --user-dir as t26a): the preset clicked last in A (env HZS_T26_EXPECT) is active after
## the restart, the engine state equals it from the start, and Esc > Graphics (input) shows that preset pressed.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const GfxState := preload("res://autotest/lib/gfxstate.gd")


func _init() -> void:
	timeout_s = 600.0


func _run(ctx):
	var want := OS.get_environment("HZS_T26_EXPECT")
	data.expected = want
	if not check("expected preset given (env HZS_T26_EXPECT)", want != "", want):
		return false
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var gs: Node = ctx.tree.root.get_node_or_null("GraphicsSettings")
	if not api_check([] if gs != null else ["GraphicsSettings autoload"]):
		return false
	await ctx.wait(2.0)
	data.settings_file = gs.call("settings_path")
	data.preset = str(gs.get("preset"))
	var st := GfxState.engine_state(ctx)
	data.state = st
	check("preset after restart == %s" % want, data.preset == want, data.preset)
	var cmp: Array = GfxState.compare(ctx, want, st)
	check("engine state = graphics.presets.%s after restart" % want, cmp[0], "; ".join(cmp[1]))
	var inp = InputSim.new(ctx)
	check("Esc > Graphics opens by input", await GfxState.open_graphics(ctx, inp), str(inp.sent.slice(-4)))
	var b := GfxState.control(ctx, "Preset" + want.capitalize()) as BaseButton
	check("menu shows Preset%s pressed" % want.capitalize(), b != null and b.button_pressed, str(b.button_pressed) if b != null else "no button")
	check("Back + Esc close the menu (game runs)", await GfxState.close_graphics(ctx, inp), str(inp.sent.slice(-4)))
	return true
