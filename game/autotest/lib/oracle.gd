extends RefCounted
## Expected values for the autotest, computed independently of the game code:
## resolved cache value (cs2/*.json, hzd/*.json) -> sheet cell fallback -> column default -> literal sheet value.
## Every lookup is remembered with its source so the results can show where a number came from.

const RESOLVED := ["cs2/weapons", "cs2/systems", "hzd/machines", "hzd/systems"]

var cache_dir := ""
var resolved := {}
var used := {}  # "<sheet>.<row>.<col>" -> {value, source}
var missing: Array = []  # keys that resolved to null (no cache value, no fallback, no default)


func _init(p_cache_dir: String) -> void:
	cache_dir = p_cache_dir
	reload()


func reload() -> void:
	## the converter writes the resolved tables during bootstrap; read them again once they exist
	for rel in RESOLVED:
		resolved[rel] = read_json(cache_dir.path_join(rel + ".json"))


static func read_json(path: String) -> Variant:
	if path == "" or not FileAccess.file_exists(path):
		return {}
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v != null else {}


func weapon(id: String, col: String) -> Variant:
	var v: Variant = _cell("weapons", WeaponsSheet.ROWS, WeaponsSheet.COLUMNS, id, col)
	if v == null and col == "kill_award":
		# weapons sheet: kill_award_class = "HUD label + fallback award" (systems kill_award.<class>)
		var cls := str(WeaponsSheet.ROWS.get(id, {}).get("kill_award_class", ""))
		if cls != "" and SystemsSheet.ROWS.has(cls):
			v = system(cls)
			var key := "weapons.%s.kill_award" % id
			used[key] = {"value": v, "source": "kill_award_class " + cls}
			missing.erase(key)
	return v


func machine(id: String, col: String) -> Variant:
	return _cell("machines", MachinesSheet.ROWS, MachinesSheet.COLUMNS, id, col)


func machine_health(id: String) -> Dictionary:
	## full health of a machine: resolved HZD InitialHealth (hzd/machines.json hzd_health) x systems
	## combat.machine_health_scale (1.0 while that row does not exist); the sheet's design health when unresolved
	var t: Variant = resolved.get("hzd/machines", {})
	if t is Dictionary and t.is_empty():
		t = read_json(cache_dir.path_join("hzd/machines.json"))
		resolved["hzd/machines"] = t
	var hzd: Variant = t.get(id, {}).get("hzd_health") if t is Dictionary and t.get(id) is Dictionary else null
	if hzd is int or hzd is float:
		var scale := 1.0
		if SystemsSheet.ROWS.has("combat.machine_health_scale"):
			scale = f(system("combat.machine_health_scale"))
		return {"value": float(hzd) * scale, "source": "hzd_health %s x machine_health_scale %s" % [str(hzd), str(scale)]}
	return {"value": f(machine(id, "health")), "source": "sheet health (hzd_health unresolved)"}


func system(id: String) -> Variant:
	return _cell("systems", SystemsSheet.ROWS, SystemsSheet.COLUMNS, id, "value")


func i(v: Variant) -> int:
	## int of a looked-up value; 0 when unresolved (the miss is in `missing` and fails the scenario)
	return int(v) if (v is int or v is float or v is bool) else (int(v) if v is String and v.is_valid_float() else 0)


func f(v: Variant) -> float:
	return float(v) if (v is int or v is float or v is bool) else (float(v) if v is String and v.is_valid_float() else NAN)


func num(v: Variant, mode: int = 0) -> float:
	## pair columns ([mode0, mode1]) -> the element for `mode`; scalars as they are
	if v is Array:
		return float(v[mini(mode, v.size() - 1)]) if not v.is_empty() else NAN
	return float(v) if v != null else NAN


func start_loadout() -> Array:
	var out := []
	for id in WeaponsSheet.ROWS:
		if WeaponsSheet.ROWS[id].get("start_loadout", false):
			out.append(id)
	return out


func wheel_items() -> Array:
	## [{id, index, price}] sorted by buy_wheel_index, rows with buy_wheel_index >= 0
	var out := []
	for id in WeaponsSheet.ROWS:
		var idx: int = int(WeaponsSheet.ROWS[id].get("buy_wheel_index", -1))
		if idx >= 0:
			out.append({"id": id, "index": idx, "price": weapon(id, "price")})
	out.sort_custom(func(a, b): return a.index < b.index)
	return out


func index_json() -> Dictionary:
	var v: Variant = read_json(cache_dir.path_join("hzd/index.json"))
	return v if v is Dictionary else {}


func cell_json(cell: Vector2i) -> Dictionary:
	var v: Variant = read_json(cell_dir(cell).path_join("cell.json"))
	return v if v is Dictionary else {}


func cell_dir(cell: Vector2i) -> String:
	return cache_dir.path_join("hzd/cells/%d_%d" % [cell.x, cell.y])


func _cell(sheet: String, rows: Dictionary, columns: Dictionary, row_id: String, col: String) -> Variant:
	var key := "%s.%s.%s" % [sheet, row_id, col]
	var row: Dictionary = rows.get(row_id, {})
	var cell: Variant = row.get(col)
	var out: Variant = cell
	var source := "sheet"
	if cell is Dictionary and (cell.has("cs2") or cell.has("hzd")):
		var src := "cs2" if cell.has("cs2") else "hzd"
		out = null
		source = "unresolved"
		var rel := "%s/%s" % [src, sheet]
		if resolved.get(rel, {}).is_empty():
			resolved[rel] = read_json(cache_dir.path_join(rel + ".json"))
		var table: Variant = resolved.get(rel, {})
		if table is Dictionary and table.get(row_id) is Dictionary and table[row_id].get(col) != null:
			out = table[row_id][col]
			source = "cache " + rel + ".json"
		elif cell.has("fallback"):
			out = cell["fallback"]
			source = "sheet fallback"
		elif columns.get(col, {}).has("default"):
			out = columns[col]["default"]
			source = "column default"
	used[key] = {"value": out, "source": source}
	if out == null and not missing.has(key):
		missing.append(key)
	return out
