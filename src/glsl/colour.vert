#version 460 core

in vec3 position;
in vec3 colour;

out vec3 frag_colour;

void main() {
    gl_Position = vec4(position, 1);
    frag_colour = colour;
}
