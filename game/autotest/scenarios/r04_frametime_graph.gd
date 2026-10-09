extends "res://autotest/lib/scenario.gd"
## r04 Record: frame-time graph 0.1 vs 0.2. Runs the dev tool tools/frametime_graph.py (python, no dependencies) on
## the 0.1.1 baseline CSV (env HZS_BASELINE_CSV) and this run's <out>/t15/frametimes.csv (or env HZS_T15_CSV) into
## <out>/records/frametime_0.1_vs_0.2.svg. The tool is found next to the project (dev checkout) or via env HZS_TOOLS.

const SVG := "records/frametime_0.1_vs_0.2.svg"


func _init() -> void:
	timeout_s = 120.0


func _run(ctx):
	var base := OS.get_environment("HZS_BASELINE_CSV")
	var cur := OS.get_environment("HZS_T15_CSV")
	if cur == "":
		cur = ctx.out_dir.path_join("t15/frametimes.csv")
	var tools := OS.get_environment("HZS_TOOLS")
	if tools == "":
		tools = ProjectSettings.globalize_path("res://").path_join("../tools").simplify_path()
	var tool := tools.path_join("frametime_graph.py")
	data.inputs = {"baseline": base, "t15": cur, "tool": tool}
	if not check("inputs exist (HZS_BASELINE_CSV, t15 frametimes.csv, frametime_graph.py)", FileAccess.file_exists(base) and FileAccess.file_exists(cur) and FileAccess.file_exists(tool), str(data.inputs)):
		return false
	var out: String = ctx.out_dir.path_join(SVG)
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var py := OS.get_environment("HZS_PYTHON")
	var res: Dictionary = await ctx.run_cmd(py if py != "" else "python", PackedStringArray([tool, base, cur, "-o", out, "--labels", "0.1.1", "0.2", "--phase", "route"]))
	data.tool_output = str(res.out).strip_edges()
	if not check("frametime_graph.py exit 0", int(res.code) == 0, data.tool_output):
		return false
	var svg := FileAccess.get_file_as_string(out)
	check("SVG exists", svg.begins_with("<svg"), out)
	for label in ["0.1.1:", "0.2:"]:
		var i := svg.find(">" + label)
		var line := svg.substr(i, 400) if i >= 0 else ""
		check("legend lists avg fps, 1 % low and worst frame for " + label.trim_suffix(":"), i >= 0 and line.contains("avg ") and line.contains("1 % low") and line.contains("worst frame"), line.substr(0, 200))
	return true
