#version 460 core

in vec3 frag_position;
in vec3 frag_normal;

out vec3 g_pos;
out vec3 g_norm;
out vec4 g_albedo_spec;

void main() {
    g_pos = frag_position;
    g_norm = normalize(frag_normal); // TODO currently these are already normal
    const vec3 colour = vec3(1, 1, 0); // TODO read from big buffer
    g_albedo_spec = vec4(colour, 1);
}
