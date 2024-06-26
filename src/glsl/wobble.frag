#version 460 core

uniform float uv_zoom;
uniform float time;

in vec2 frag_position;
in vec3 frag_colour;

out vec4 colour;

// Adapted https://www.shadertoy.com/view/7sdXzM

float interpIter(float t, float a, float b) {
    const float t_inv = 1 - t;
    return (
        t *     t_inv * t_inv * a * 3.0 +
        t * t * t_inv *         b * 3.0 +
        t * t * t
    );
}

float interp(float t, float a, float b) {
    return interpIter(
        interpIter(
            clamp(t, 0, 1),
            a, b
        ),
        a, b
    );
}

void main() {
    const vec2 uv = frag_position * 0.5 * uv_zoom + 0.5;
    const float thres = interp(
        uv.x,
        cos(time * 6.283185307) * 0.5 + 0.5,
        sin(time * 6.283185307) * 0.5 + 0.5
    );
    colour = vec4(mix(
        1 - frag_colour,
        frag_colour,
        step(uv.y, thres)
    ), 1);
}
