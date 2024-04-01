#version 460 core

uniform sampler2D g_pos;
uniform sampler2D g_norm;
uniform sampler2D g_albedo_spec;
uniform sampler2D ssao;

in vec2 uv;

out vec4 colour;

void main() {
    const vec3 pos = texture(g_pos, uv).xyz;
    const vec3 norm = texture(g_norm, uv).xyz;
    const vec3 albedo = texture(g_albedo_spec, uv).rgb;
    const float spec = texture(g_albedo_spec, uv).a;
    const float occ = texture(ssao, uv).r;

    colour = vec4(albedo, 1) * occ;
}
