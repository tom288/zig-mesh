#version 460 core

uniform mat4 model;
uniform mat4 view;
uniform mat4 proj;

in vec3 position;
in uvec4 padding;
in vec3 normal;
in uvec4 colour;

out vec3 frag_position;
out vec3 frag_normal;
out vec4 frag_colour;

void main() {
    const vec4 view_pos = view * model * vec4(position, 1);
    gl_Position = proj * view_pos;
    frag_position = view_pos.xyz;
    frag_normal = transpose(inverse(mat3(view * model))) * normal;
    frag_colour = colour / 255.999;
    // Stop padding from being optimised away
    frag_colour.a += padding.a;
}
