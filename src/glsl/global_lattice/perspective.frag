#version 460 core

in vec3 frag_position;
in vec3 frag_normal;

out vec4 colour;

void main() {
   colour = vec4(vec3(1, 1, 0), 1); // TODO read from big buffer
}
