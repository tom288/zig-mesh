#version 460 core

in vec3 frag_position;
in vec3 frag_normal;
in vec4 frag_colour;

out vec3 g_pos;
out vec3 g_norm;
out vec4 g_albedo_spec;

void main() {
    g_pos = frag_position;
    g_norm = normalize(frag_normal); // TODO currently these are already normal
    g_albedo_spec = frag_colour;
}
