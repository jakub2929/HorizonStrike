extends RefCounted
## Minimal binary glTF reader for the converter's static meshes (hzd/meshes/<id>.glb): positions, normals, UV0,
## indices of triangle primitives, node transforms, and material facts (base colour factor/texture image name,
## alpha mode, double sided). Pure data - safe on worker threads (no RenderingServer resources are created).
## Textures stay external (../textures/<hash>.png) and are loaded once per hash by the mesh library.

const MAGIC := 0x46546C67      # "glTF"
const CHUNK_JSON := 0x4E4F534A
const CHUNK_BIN := 0x004E4942
const COMPONENTS := {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
const COMP_SIZE := {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}


## Returns {} on failure, else {surfaces: [{arrays, material}], materials: [...], aabb: AABB, tris: int,
## alpha: bool, faces: PackedVector3Array (only when want_faces)}.
static func read(path: String, want_faces: bool = false) -> Dictionary:
	var b := FileAccess.get_file_as_bytes(path)
	if b.size() < 20 or b.decode_u32(0) != MAGIC:
		return {}
	var jlen := b.decode_u32(12)
	if b.decode_u32(16) != CHUNK_JSON:
		return {}
	var j = JSON.parse_string(b.slice(20, 20 + jlen).get_string_from_utf8())
	if typeof(j) != TYPE_DICTIONARY:
		return {}
	var bin := PackedByteArray()
	var off := 20 + jlen
	if off + 8 <= b.size() and b.decode_u32(off + 4) == CHUNK_BIN:
		var blen := b.decode_u32(off)
		bin = b.slice(off + 8, off + 8 + blen)
	var out := {"surfaces": [], "materials": _materials(j), "tris": 0, "alpha": false}
	for m in out["materials"]:
		if m["alpha"]:
			out["alpha"] = true
	var aabb := AABB()
	var first := true
	var faces := PackedVector3Array()
	var nodes: Array = j.get("nodes", [])
	var roots: Array = []
	var scenes: Array = j.get("scenes", [])
	if not scenes.is_empty():
		roots = scenes[int(j.get("scene", 0))].get("nodes", [])
	else:
		for i in nodes.size():
			roots.append(i)
	var stack: Array = []
	for r in roots:
		stack.append([int(r), Transform3D.IDENTITY])
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var node: Dictionary = nodes[item[0]]
		var xf: Transform3D = (item[1] as Transform3D) * _node_xf(node)
		for c in node.get("children", []):
			stack.append([int(c), xf])
		if not node.has("mesh"):
			continue
		var mesh: Dictionary = j["meshes"][int(node["mesh"])]
		for prim in mesh.get("primitives", []):
			if int(prim.get("mode", 4)) != 4:
				continue
			var attrs: Dictionary = prim.get("attributes", {})
			if not attrs.has("POSITION"):
				continue
			var pos := _vec3(j, bin, int(attrs["POSITION"]))
			var nrm := _vec3(j, bin, int(attrs["NORMAL"])) if attrs.has("NORMAL") else PackedVector3Array()
			var uv := _vec2(j, bin, int(attrs["TEXCOORD_0"])) if attrs.has("TEXCOORD_0") else PackedVector2Array()
			var col := _colors(j, bin, int(attrs["COLOR_0"])) if attrs.has("COLOR_0") else PackedColorArray()
			var idx := _indices(j, bin, int(prim["indices"])) if prim.has("indices") else PackedInt32Array()
			if idx.is_empty():
				idx.resize(pos.size())
				for i in pos.size():
					idx[i] = i
			# glTF front faces are counter-clockwise, Godot's are clockwise
			for t in range(0, idx.size() - 2, 3):
				var tmp := idx[t + 1]
				idx[t + 1] = idx[t + 2]
				idx[t + 2] = tmp
			if not xf.is_equal_approx(Transform3D.IDENTITY):
				var nb := xf.basis.inverse().transposed()
				for i in pos.size():
					pos[i] = xf * pos[i]
				for i in nrm.size():
					nrm[i] = (nb * nrm[i]).normalized()
			var pa: Dictionary = j["accessors"][int(attrs["POSITION"])]
			var paabb := AABB()
			if xf.is_equal_approx(Transform3D.IDENTITY) and pa.has("min") and pa.has("max"):
				var mn: Array = pa["min"]
				var mx: Array = pa["max"]
				paabb = AABB(Vector3(mn[0], mn[1], mn[2]), Vector3(mx[0] - mn[0], mx[1] - mn[1], mx[2] - mn[2]))
			else:
				paabb = AABB(pos[0], Vector3.ZERO) if pos.size() > 0 else AABB()
				for p in pos:
					paabb = paabb.expand(p)
			aabb = paabb if first else aabb.merge(paabb)
			first = false
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = pos
			if nrm.size() == pos.size():
				arrays[Mesh.ARRAY_NORMAL] = nrm
			if uv.size() == pos.size():
				arrays[Mesh.ARRAY_TEX_UV] = uv
			if col.size() == pos.size():
				arrays[Mesh.ARRAY_COLOR] = col
			arrays[Mesh.ARRAY_INDEX] = idx
			out["surfaces"].append({"arrays": arrays, "material": int(prim.get("material", -1))})
			out["tris"] = int(out["tris"]) + idx.size() / 3
			if want_faces:
				for t in range(0, idx.size() - 2, 3):
					faces.append(pos[idx[t]])
					faces.append(pos[idx[t + 1]])
					faces.append(pos[idx[t + 2]])
	out["aabb"] = aabb
	if want_faces:
		out["faces"] = faces
	return out


static func _node_xf(n: Dictionary) -> Transform3D:
	if n.has("matrix"):
		var m: Array = n["matrix"]
		var basis := Basis(Vector3(m[0], m[1], m[2]), Vector3(m[4], m[5], m[6]), Vector3(m[8], m[9], m[10]))
		return Transform3D(basis, Vector3(m[12], m[13], m[14]))
	var t: Array = n.get("translation", [0, 0, 0])
	var r: Array = n.get("rotation", [0, 0, 0, 1])
	var s: Array = n.get("scale", [1, 1, 1])
	var basis2 := Basis(Quaternion(r[0], r[1], r[2], r[3])).scaled(Vector3(s[0], s[1], s[2]))
	return Transform3D(basis2, Vector3(t[0], t[1], t[2]))


static func _materials(j: Dictionary) -> Array:
	var images: Array = j.get("images", [])
	var textures: Array = j.get("textures", [])
	var out: Array = []
	for m in j.get("materials", []):
		var pbr: Dictionary = m.get("pbrMetallicRoughness", {})
		var img_name := _image_name(pbr.get("baseColorTexture", {}), images, textures)
		var f: Array = pbr.get("baseColorFactor", [1, 1, 1, 1])
		var mode := str(m.get("alphaMode", "OPAQUE"))
		out.append({"name": str(m.get("name", "")), "image": img_name, "color": Color(f[0], f[1], f[2], f[3]),
			"alpha": mode != "OPAQUE", "blend": mode == "BLEND", "cutoff": float(m.get("alphaCutoff", 0.5)),
			"double_sided": bool(m.get("doubleSided", false)), "roughness": float(pbr.get("roughnessFactor", 1.0)),
			"metallic": float(pbr.get("metallicFactor", 1.0)),
			# normal map (tangent space, RG = XY) and packed occlusion (R) / roughness (G) / metallic (B)
			"normal": _image_name(m.get("normalTexture", {}), images, textures),
			"orm": _image_name(pbr.get("metallicRoughnessTexture", {}), images, textures),
			"occlusion": _image_name(m.get("occlusionTexture", {}), images, textures)})
	return out


## Cache texture name (file name without extension, hzd/textures/<name>.dds|png) of a glTF textureInfo.
static func _image_name(info: Variant, images: Array, textures: Array) -> String:
	if typeof(info) != TYPE_DICTIONARY or not (info as Dictionary).has("index"):
		return ""
	var ti := int(info["index"])
	if ti < 0 or ti >= textures.size() or not textures[ti].has("source"):
		return ""
	var si := int(textures[ti]["source"])
	if si < 0 or si >= images.size():
		return ""
	var im: Dictionary = images[si]
	if im.has("uri"):
		return str(im["uri"]).get_file().get_basename()
	return str(im.get("name", ""))


## Raw bytes + layout of an accessor: [data, count, comps, comp_type, stride, normalized].
static func _acc(j: Dictionary, bin: PackedByteArray, ai: int) -> Array:
	var a: Dictionary = j["accessors"][ai]
	var comps: int = COMPONENTS.get(str(a.get("type", "SCALAR")), 1)
	var ct := int(a.get("componentType", 5126))
	var count := int(a.get("count", 0))
	if not a.has("bufferView"):
		return [PackedByteArray(), count, comps, ct, 0, false]
	var bv: Dictionary = j["bufferViews"][int(a["bufferView"])]
	var start := int(bv.get("byteOffset", 0)) + int(a.get("byteOffset", 0))
	var elem: int = comps * int(COMP_SIZE.get(ct, 4))
	var stride := int(bv.get("byteStride", 0))
	if stride == 0:
		stride = elem
	var end := start + stride * (count - 1) + elem
	return [bin.slice(start, end), count, comps, ct, stride, bool(a.get("normalized", false))]


static func _floats(acc: Array) -> PackedFloat32Array:
	var data: PackedByteArray = acc[0]
	var count: int = acc[1]
	var comps: int = acc[2]
	var ct: int = acc[3]
	var stride: int = acc[4]
	if ct == 5126 and stride == comps * 4:
		return data.slice(0, count * comps * 4).to_float32_array()
	var out := PackedFloat32Array()
	out.resize(count * comps)
	var cs: int = COMP_SIZE.get(ct, 4)
	for i in count:
		for c in comps:
			var o := i * stride + c * cs
			var v := 0.0
			match ct:
				5126:
					v = data.decode_float(o)
				5121:
					v = data.decode_u8(o) / 255.0
				5123:
					v = data.decode_u16(o) / 65535.0
				5120:
					v = maxf(data.decode_s8(o) / 127.0, -1.0)
				5122:
					v = maxf(data.decode_s16(o) / 32767.0, -1.0)
			out[i * comps + c] = v
	return out


## COLOR_0 (VEC3 or VEC4; float or normalised integers) -> PackedColorArray.
static func _colors(j: Dictionary, bin: PackedByteArray, ai: int) -> PackedColorArray:
	var acc := _acc(j, bin, ai)
	var comps: int = acc[2]
	var f := _floats(acc)
	var out := PackedColorArray()
	if comps < 3:
		return out
	out.resize(f.size() / comps)
	for i in out.size():
		out[i] = Color(f[i * comps], f[i * comps + 1], f[i * comps + 2], f[i * comps + 3] if comps == 4 else 1.0)
	return out


static func _vec3(j: Dictionary, bin: PackedByteArray, ai: int) -> PackedVector3Array:
	var acc := _acc(j, bin, ai)
	if int(acc[3]) == 5126 and int(acc[4]) == 12:
		return (acc[0] as PackedByteArray).slice(0, int(acc[1]) * 12).to_vector3_array()
	var f := _floats(acc)
	var out := PackedVector3Array()
	out.resize(f.size() / 3)
	for i in out.size():
		out[i] = Vector3(f[i * 3], f[i * 3 + 1], f[i * 3 + 2])
	return out


static func _vec2(j: Dictionary, bin: PackedByteArray, ai: int) -> PackedVector2Array:
	var acc := _acc(j, bin, ai)
	if int(acc[3]) == 5126 and int(acc[4]) == 8:
		return (acc[0] as PackedByteArray).slice(0, int(acc[1]) * 8).to_vector2_array()
	var f := _floats(acc)
	var out := PackedVector2Array()
	out.resize(f.size() / 2)
	for i in out.size():
		out[i] = Vector2(f[i * 2], f[i * 2 + 1])
	return out


static func _indices(j: Dictionary, bin: PackedByteArray, ai: int) -> PackedInt32Array:
	var acc := _acc(j, bin, ai)
	var data: PackedByteArray = acc[0]
	var count: int = acc[1]
	var ct: int = acc[3]
	var stride: int = acc[4]
	if ct == 5125 and stride == 4:
		return data.slice(0, count * 4).to_int32_array()
	var out := PackedInt32Array()
	out.resize(count)
	for i in count:
		match ct:
			5123:
				out[i] = data.decode_u16(i * stride)
			5121:
				out[i] = data.decode_u8(i * stride)
			_:
				out[i] = data.decode_u32(i * stride)
	return out
