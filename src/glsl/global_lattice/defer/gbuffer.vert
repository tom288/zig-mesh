#version 460 core

uniform mat4 model;
uniform mat4 view;
uniform mat4 proj;

in vec3 position;
in uint axis;

out vec3 frag_position;
out vec3 frag_normal;

void main() {
    const vec4 view_pos = view * model * vec4(position, 1);
    gl_Position = proj * view_pos;
    frag_position = view_pos.xyz;

    frag_normal = vec3(0);
    frag_normal[axis] = 1;
    // TODO pass camera position and use it to flip the normal
    frag_normal = transpose(inverse(mat3(view * model))) * frag_normal;
}
