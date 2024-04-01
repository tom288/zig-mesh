#version 460 core

in vec2 pos;
in vec2 _uv;

out vec2 uv;

void main() {
    uv = _uv;
    gl_Position = vec4(pos, 0, 1);
}
