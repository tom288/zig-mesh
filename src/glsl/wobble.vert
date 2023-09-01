#version 410 core

uniform vec2 offset;
uniform mat4 identity;

in vec2 position;
in vec3 colour;

out vec2 frag_position;
out vec3 frag_colour;

void main()
{
    gl_Position = identity * vec4(position + (offset - 0.5), 0.0, 1.0);
    frag_position = position;
    frag_colour = colour;
}
