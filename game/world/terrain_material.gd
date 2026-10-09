extends RefCounted
## Terrain material: the cell's albedo (and normal map when present) plus a procedural detail layer (our own noise,
## tiling every few metres) so the 0.5 m/px HZD albedo does not look blurry up close. Slopes get a little darker.

const SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform bool has_albedo = false;
uniform vec4 base_color : source_color = vec4(0.36, 0.45, 0.28, 1.0);
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_disable;
uniform bool has_normal = false;
uniform sampler2D detail_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float detail_scale = 0.22;
uniform float detail_strength = 0.35;
uniform float detail_fade = 120.0;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 col = has_albedo ? texture(albedo_tex, UV).rgb : base_color.rgb;
	float dist = length(world_pos - (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz);
	float near_k = clamp(1.0 - dist / detail_fade, 0.0, 1.0);
	float d1 = texture(detail_tex, world_pos.xz * detail_scale).r;
	float d2 = texture(detail_tex, world_pos.xz * detail_scale * 0.13).r;
	float detail = mix(1.0, 0.75 + 0.5 * d1, detail_strength * near_k) * mix(1.0, 0.85 + 0.3 * d2, 0.5);
	float slope = 1.0 - clamp(world_normal.y, 0.0, 1.0);
	col *= detail * (1.0 - 0.25 * smoothstep(0.25, 0.6, slope));
	ALBEDO = col;
	ROUGHNESS = 0.92;
	SPECULAR = 0.2;
	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
	} else {
		NORMAL_MAP = mix(vec3(0.5, 0.5, 1.0), texture(detail_normal, world_pos.xz * detail_scale).rgb, near_k);
		NORMAL_MAP_DEPTH = 0.6;
	}
}
"""

static var _shader: Shader
static var _detail: NoiseTexture2D
static var _detail_n: NoiseTexture2D


static func make(albedo: Texture2D, normal: Texture2D) -> ShaderMaterial:
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
	if normal:
		m.set_shader_parameter("normal_tex", normal)
	m.set_shader_parameter("detail_tex", _detail)
	m.set_shader_parameter("detail_normal", _detail_n)
	return m
