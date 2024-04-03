#version 460 core

uniform mat4 model;
uniform mat4 view;
uniform mat4 proj;

in vec3 position;
in uvec4 padding;
in vec3 normal;
in uvec4 colour;

out vec3 frag_colour;

void main() {
   gl_Position = proj * view * model * vec4(position, 1);
   frag_colour = colour.rgb / 255.999;
   // Stop padding and normal from being optimised away
   frag_colour += padding.a * normal.r;
}
