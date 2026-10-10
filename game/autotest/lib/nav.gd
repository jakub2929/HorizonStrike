extends RefCounted
## Terrain path planning for the route walker (reading state only): A* on a grid of terrain heights from
## Game.world.height_at, slope-weighted, too-steep steps impassable. Unknown heights (cell not loaded) are passable at
## a higher cost, so a plan can reach into cells that are still streaming in.

const MAX_SLOPE := 0.75  # rise / run between two grid nodes (~37 deg)


static func plan(ctx, from: Vector3, to: Vector3, step: float = 8.0, margin: float = 160.0) -> Array:
	var w: Variant = ctx.game.get("world") if ctx.game != null and "world" in ctx.game else null
	if not (w is Object and w.has_method("height_at")):
		return [to]
	var x0 := minf(from.x, to.x) - margin
	var z0 := minf(from.z, to.z) - margin
	var nx := int(ceil((maxf(from.x, to.x) + margin - x0) / step)) + 1
	var nz := int(ceil((maxf(from.z, to.z) + margin - z0) / step)) + 1
	var n := nx * nz
	var hts := PackedFloat32Array()
	hts.resize(n)
	for iz in nz:
		for ix in nx:
			var hv: float = float(w.call("height_at", Vector3(x0 + ix * step, 0.0, z0 + iz * step)))
			hts[iz * nx + ix] = hv
	var si := _idx(from, x0, z0, step, nx, nz)
	var gi := _idx(to, x0, z0, step, nx, nz)
	var g := PackedFloat32Array()
	g.resize(n)
	g.fill(INF)
	var came := PackedInt32Array()
	came.resize(n)
	came.fill(-1)
	var closed := PackedByteArray()
	closed.resize(n)
	g[si] = 0.0
	var open := [[_h(si, gi, nx, step), si]]  # binary heap of [f, index]
	var dirs := [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]]
	var found := false
	var expanded := 0
	while not open.is_empty():
		var cur: int = _pop(open)[1]
		if closed[cur] == 1:
			continue
		closed[cur] = 1
		expanded += 1
		if cur == gi:
			found = true
			break
		if expanded > 60000:
			break
		var cx := cur % nx
		var cz := cur / nx
		var hc: float = hts[cur]
		for dv in dirs:
			var ax: int = cx + dv[0]
			var az: int = cz + dv[1]
			if ax < 0 or az < 0 or ax >= nx or az >= nz:
				continue
			var ni := az * nx + ax
			if closed[ni] == 1:
				continue
			var run := step * (1.4142 if dv[0] != 0 and dv[1] != 0 else 1.0)
			var hn: float = hts[ni]
			var cost := run
			if is_nan(hn) or is_nan(hc):
				cost *= 1.5
			else:
				var slope := absf(hn - hc) / run
				if slope > MAX_SLOPE:
					continue
				cost *= 1.0 + 6.0 * slope * slope
			var ng: float = g[cur] + cost
			if ng < g[ni]:
				g[ni] = ng
				came[ni] = cur
				_push(open, [ng + _h(ni, gi, nx, step), ni])
	if not found:
		return []
	var path := []
	var i := gi
	while i != -1:
		path.push_front(Vector3(x0 + (i % nx) * step, hts[i] if not is_nan(hts[i]) else from.y, z0 + (i / nx) * step))
		i = came[i]
	# thin out: a point every ~3 nodes, keep the last
	var out := []
	for k in range(0, path.size(), 3):
		out.append(path[k])
	if out.is_empty() or out[-1] != path[-1]:
		out.append(path[-1])
	return out


static func _idx(p: Vector3, x0: float, z0: float, step: float, nx: int, nz: int) -> int:
	var ix := clampi(int(round((p.x - x0) / step)), 0, nx - 1)
	var iz := clampi(int(round((p.z - z0) / step)), 0, nz - 1)
	return iz * nx + ix


static func _h(a: int, b: int, nx: int, step: float) -> float:
	return Vector2(a % nx - b % nx, a / nx - b / nx).length() * step


static func _push(heap: Array, item: Array) -> void:
	heap.append(item)
	var i := heap.size() - 1
	while i > 0:
		var parent := (i - 1) / 2
		if heap[parent][0] <= heap[i][0]:
			break
		var tmp: Array = heap[parent]
		heap[parent] = heap[i]
		heap[i] = tmp
		i = parent


static func _pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if not heap.is_empty():
		heap[0] = last
		var i := 0
		var n := heap.size()
		while true:
			var l := 2 * i + 1
			var r := l + 1
			var m := i
			if l < n and heap[l][0] < heap[m][0]:
				m = l
			if r < n and heap[r][0] < heap[m][0]:
				m = r
			if m == i:
				break
			var tmp: Array = heap[m]
			heap[m] = heap[i]
			heap[i] = tmp
			i = m
	return top
