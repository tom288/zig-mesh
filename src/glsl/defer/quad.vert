#version 460 core

in vec2 pos;

out vec2 uv;

void main() {
    uv = (pos + 1) / 2;
    gl_Position = vec4(pos, 0, 1);
}
