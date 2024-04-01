#version 460 core

uniform sampler2D tex;

in vec2 uv;

out float colour;

const int RAD = 2;

void main() {
    vec2 texel_size = 1 / vec2(textureSize(tex, 0));
    float result = 0;
    for (int x = -RAD; x <= RAD; ++x) {
        for (int y = -RAD; y <= RAD; ++y) {
            vec2 offset = vec2(float(x), float(y)) * texel_size;
            result += texture(tex, uv + offset).r;
        }
    }
    colour = result / pow(RAD * 2 + 1, 2);
}
