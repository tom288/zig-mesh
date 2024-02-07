#version 430 core

uniform mat4 model_to_clip;

in vec3 position;
in vec3 colour;

out vec3 frag_colour;

void main()
{
   gl_Position = model_to_clip * vec4(position, 1.0f);
   frag_colour = colour;
}
