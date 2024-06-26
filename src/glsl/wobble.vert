#version 460 core

in vec2 position;
in vec3 colour;

out vec2 frag_position;
out vec3 frag_colour;

void main() {
    gl_Position = vec4(position, 0, 1);
    frag_position = position;
    frag_colour = colour;
}
