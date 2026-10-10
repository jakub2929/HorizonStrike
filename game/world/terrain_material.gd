extends RefCounted
## Terrain material (0.2 H4). With cell.json terrain.layers: four material layers (cell masks.dds RGBA = weights,
## renormalised in the shader because BC7 drifts the sum up to ~0.2), each with colour, normal and ORM maps tiled
## every tile_m metres in world space; the rock layer is triplanar so cliffs do not stretch. Near the camera the
## layers carry the detail, the cell's own albedo (the HZD colour, 0.25 m/px) tints them and takes over with
## distance. Normals: the cell's world-space normal map (or the geometry normal) plus the layers' detail normals.
## Without layers: albedo + normal map + a procedural detail noise as in 0.1.

const MeshLib := preload("res://world/mesh_library.gd")
const Log := preload("res://core/log.gd")
const Sheets := preload("res://core/sheets.gd")

const SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform bool has_albedo = false;
uniform vec4 base_color : source_color = vec4(0.36, 0.45, 0.28, 1.0);
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_disable;
uniform bool has_normal = false;
uniform bool normal_world = false;   // normal_tex RG = world X/Z (converter "world_xz"), Y rebuilt
uniform sampler2D detail_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float detail_scale = 0.22;
uniform float detail_strength = 0.35;
uniform float detail_fade = 120.0;

uniform bool has_layers = false;
uniform sampler2D masks : filter_linear_mipmap, repeat_disable;
uniform sampler2D l0_alb : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D l1_alb : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D l2_alb : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D l3_alb : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D l0_nrm : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D l1_nrm : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D l2_nrm : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D l3_nrm : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D l0_orm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D l1_orm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D l2_orm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D l3_orm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 tile_m = vec4(4.0);
uniform float macro_tint = 0.55;      // how much the cell albedo colours the near layers
uniform float macro_start = 60.0;     // m: layers fade to the cell albedo between start and end
uniform float macro_end = 260.0;
uniform float layer_normal_strength = 0.8;
uniform bool layer_gloss = true;       // render.terrain_layer_gloss: ORM G is gloss (roughness = 1 - G)
uniform float min_roughness = 0.6;     // render.terrain_min_roughness

varying vec3 world_pos;
varying vec3 world_normal;

vec3 rebuild_normal(vec2 rg) {
	vec2 n = rg * 2.0 - 1.0;
	return vec3(n, sqrt(max(0.0, 1.0 - dot(n, n))));
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float dist = length(world_pos - (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz);
	vec3 macro = has_albedo ? texture(albedo_tex, UV).rgb : base_color.rgb;
	// macro normal in world space
	vec3 nw = world_normal;
	if (has_normal && normal_world) {
		vec2 nxz = texture(normal_tex, UV).rg * 2.0 - 1.0;
		nw = normalize(vec3(nxz.x, sqrt(max(0.0, 1.0 - dot(nxz, nxz))), nxz.y));
	}
	if (has_layers) {
		vec4 w = max(texture(masks, UV), vec4(0.0));
		w /= max(dot(w, vec4(1.0)), 0.001);
		vec2 u0 = world_pos.xz / tile_m.x;
		vec2 u1 = world_pos.xz / tile_m.y;
		vec2 u2 = world_pos.xz / tile_m.z;
		// rock (layer 3): triplanar
		vec3 bw = pow(abs(nw), vec3(4.0));
		bw /= max(bw.x + bw.y + bw.z, 0.001);
		vec2 rx = world_pos.zy / tile_m.w;
		vec2 ry = world_pos.xz / tile_m.w;
		vec2 rz = world_pos.xy / tile_m.w;
		vec3 a3 = texture(l3_alb, rx).rgb * bw.x + texture(l3_alb, ry).rgb * bw.y + texture(l3_alb, rz).rgb * bw.z;
		vec3 o3 = texture(l3_orm, rx).rgb * bw.x + texture(l3_orm, ry).rgb * bw.y + texture(l3_orm, rz).rgb * bw.z;
		vec2 n3 = texture(l3_nrm, ry).rg;
		vec3 alb = texture(l0_alb, u0).rgb * w.x + texture(l1_alb, u1).rgb * w.y + texture(l2_alb, u2).rgb * w.z + a3 * w.w;
		vec3 orm = texture(l0_orm, u0).rgb * w.x + texture(l1_orm, u1).rgb * w.y + texture(l2_orm, u2).rgb * w.z + o3 * w.w;
		vec2 nrg = texture(l0_nrm, u0).rg * w.x + texture(l1_nrm, u1).rg * w.y + texture(l2_nrm, u2).rg * w.z + n3 * w.w;
		// the cell albedo tints the layers near by (keeps HZD's colour variation) and replaces them far away
		float macro_l = max(dot(macro, vec3(0.299, 0.587, 0.114)), 0.04);
		float alb_l = max(dot(alb, vec3(0.299, 0.587, 0.114)), 0.04);
		vec3 near_col = mix(alb, alb * macro / macro_l * alb_l / max(alb_l, 0.04), macro_tint);
		near_col = mix(near_col, macro, 0.25);
		float far_k = smoothstep(macro_start, macro_end, dist);
		ALBEDO = mix(near_col, macro, far_k);
		float rough = max(layer_gloss ? 1.0 - orm.g : orm.g, min_roughness);
		ROUGHNESS = mix(rough, 0.9, far_k);
		AO = mix(orm.r, 1.0, far_k);
		AO_LIGHT_AFFECT = 0.4;
		SPECULAR = 0.25;
		// detail normal: layer XY perturbs the macro normal in world X/Z (terrain is mostly up-facing)
		vec3 d = rebuild_normal(nrg);
		float ns = layer_normal_strength * (1.0 - far_k);
		nw = normalize(nw + vec3(d.x, 0.0, -d.y) * ns);
		NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	} else {
		float near_k = clamp(1.0 - dist / detail_fade, 0.0, 1.0);
		float d1 = texture(detail_tex, world_pos.xz * detail_scale).r;
		float d2 = texture(detail_tex, world_pos.xz * detail_scale * 0.13).r;
		float detail = mix(1.0, 0.75 + 0.5 * d1, detail_strength * near_k) * mix(1.0, 0.85 + 0.3 * d2, 0.5);
		float slope = 1.0 - clamp(world_normal.y, 0.0, 1.0);
		ALBEDO = macro * detail * (1.0 - 0.25 * smoothstep(0.25, 0.6, slope));
		ROUGHNESS = 0.92;
		SPECULAR = 0.2;
		if (has_normal && normal_world) {
			NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
			NORMAL_MAP = mix(vec3(0.5, 0.5, 1.0), texture(detail_normal, world_pos.xz * detail_scale).rgb, near_k);
			NORMAL_MAP_DEPTH = 0.6;
		} else if (has_normal) {
			NORMAL_MAP = texture(normal_tex, UV).rgb;
		} else {
			NORMAL_MAP = mix(vec3(0.5, 0.5, 1.0), texture(detail_normal, world_pos.xz * detail_scale).rgb, near_k);
			NORMAL_MAP_DEPTH = 0.6;
		}
	}
}
"""

static var _shader: Shader
static var _detail: NoiseTexture2D
static var _detail_n: NoiseTexture2D
static var _logged := false
static var _layer_tex := {}   # cache path -> Texture2D (the four layer sets are shared by every cell)


## layers (optional): {"masks": Texture2D, "albedo": [4 paths], "normal": [4], "orm": [4], "tile": Vector4} with
## absolute file paths of the shared layer DDS files (loaded once per session).
static func make(albedo: Texture2D, normal: Texture2D, normal_world: bool = false, layers: Dictionary = {}) -> ShaderMaterial:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
		var noise := FastNoiseLite.new()
		noise.seed = 7
		noise.frequency = 0.02
		noise.fractal_octaves = 4
		_detail = NoiseTexture2D.new()
		_detail.width = 256
		_detail.height = 256
		_detail.seamless = true
		_detail.generate_mipmaps = true
		_detail.noise = noise
		_detail_n = NoiseTexture2D.new()
		_detail_n.width = 256
		_detail_n.height = 256
		_detail_n.seamless = true
		_detail_n.as_normal_map = true
		_detail_n.bump_strength = 6.0
		_detail_n.generate_mipmaps = true
		_detail_n.noise = noise
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("has_albedo", albedo != null)
	if albedo:
		m.set_shader_parameter("albedo_tex", albedo)
	m.set_shader_parameter("has_normal", normal != null)
	m.set_shader_parameter("normal_world", normal_world)
	if normal:
		m.set_shader_parameter("normal_tex", normal)
	m.set_shader_parameter("detail_tex", _detail)
	m.set_shader_parameter("detail_normal", _detail_n)
	var ok: bool = layers.get("masks") != null
	if ok:
		for kind in ["albedo", "normal", "orm"]:
			var paths: Array = layers.get(kind, [])
			if paths.size() < 4:
				ok = false
				break
			for i in 4:
				var t := layer_texture(str(paths[i]))
				if t == null:
					ok = false
					break
				m.set_shader_parameter("l%d_%s" % [i, {"albedo": "alb", "normal": "nrm", "orm": "orm"}[kind]], t)
	m.set_shader_parameter("has_layers", ok)
	if layers.has("masks") and not _logged:
		_logged = true
		Log.info("terrain: %s (layer textures loaded: %d)" % ["4 material layers + masks" if ok else "layers given but incomplete -> albedo only", _layer_tex.size()])
	if ok:
		m.set_shader_parameter("masks", layers["masks"])
		m.set_shader_parameter("tile_m", layers.get("tile", Vector4(4, 4, 4, 6)))
		m.set_shader_parameter("layer_gloss", Sheets.sys_bool("render.terrain_layer_gloss", true))
		m.set_shader_parameter("min_roughness", Sheets.sys_num("render.terrain_min_roughness", 0.6))
	return m


## Shared layer texture (main thread; one GPU upload per file per session).
static func layer_texture(path: String) -> Texture2D:
	if _layer_tex.has(path):
		return _layer_tex[path]
	var tex: Texture2D = null
	if FileAccess.file_exists(path):
		var img: Image = MeshLib.load_dds(path) if path.get_extension().to_lower() == "dds" else Image.load_from_file(path)
		if img:
			if not img.is_compressed() and not img.has_mipmaps():
				img.generate_mipmaps()
			tex = ImageTexture.create_from_image(img)
	_layer_tex[path] = tex
	return tex
