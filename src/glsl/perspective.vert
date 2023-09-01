#version 410 core

uniform mat4 model;
uniform mat4 view;
uniform mat4 projection;

in vec3 position;
in vec3 color;

out vec3 frag_colour;

void main()
{
   gl_Position = projection * view * model * vec4(position, 1.0f);
   frag_colour = color;
}
