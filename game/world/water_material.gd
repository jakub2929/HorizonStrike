extends RefCounted
## Water surfaces (cell.json water.instances, 0.2 H6): one shared material. The converted water meshes carry only
## positions and normals (HZD's water shading is compiled shader code), so the look is ours: a translucent blue-green
## body, two scrolling noise normals in world X/Z, Fresnel-weighted opacity and a sharp sun highlight.

const SHADER := """
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 shallow_color : source_color = vec4(0.20, 0.36, 0.34, 1.0);
uniform vec4 deep_color : source_color = vec4(0.04, 0.12, 0.16, 1.0);
uniform sampler2D ripple : filter_linear_mipmap, repeat_enable;
uniform float ripple_strength = 0.35;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 uv1 = world_pos.xz * 0.045 + TIME * vec2(0.018, 0.009);
	vec2 uv2 = world_pos.xz * 0.11 - TIME * vec2(0.012, 0.021);
	vec2 d = (texture(ripple, uv1).rg + texture(ripple, uv2).rg) - 1.0;
	vec3 n = world_normal.y < 0.0 ? -world_normal : world_normal;
	n = normalize(n + vec3(d.x, 0.0, d.y) * ripple_strength);
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	ALBEDO = mix(deep_color.rgb, shallow_color.rgb, 0.35 + 0.4 * fres);
	ROUGHNESS = 0.04;
	METALLIC = 0.0;
	SPECULAR = 0.7;
	ALPHA = mix(0.72, 0.96, fres);
}
"""

static var _mat: ShaderMaterial


static func get_material() -> ShaderMaterial:
	if _mat:
		return _mat
	var sh := Shader.new()
	sh.code = SHADER
	var noise := FastNoiseLite.new()
	noise.seed = 21
	noise.frequency = 0.03
	noise.fractal_octaves = 3
	var tex := NoiseTexture2D.new()
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	tex.as_normal_map = true
	tex.bump_strength = 4.0
	tex.generate_mipmaps = true
	tex.noise = noise
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.set_shader_parameter("ripple", tex)
	return _mat
