#version 460 core

uniform sampler2D g_pos;
uniform sampler2D g_norm;
uniform sampler2D noise;
uniform mat4 projection;
uniform vec3 samples[64];
uniform vec2 resolution;

in vec2 uv;

out float colour;

const uint kernel_size = 64;
const float radius = 4;
const float bias = 1.0 / 32;
const float strength = 0.25;

void main() {
    const vec3 pos = texture(g_pos, uv).xyz;
    const vec3 norm = texture(g_norm, uv).xyz;
    const vec3 random_vec = texture(noise, uv * resolution / textureSize(noise, 0)).xyz;
    // Create TBN change-of-basis matrix for tangent-space -> view-space
    const vec3 tangent = normalize(random_vec - norm * dot(random_vec, norm));
    const vec3 bitangent = cross(norm, tangent);
    const mat3 tbn = mat3(tangent, bitangent, norm);
    // Iterate over sample kernel and calculate occlusion
    float occ = 0;
    for (uint i = 0; i < kernel_size; ++i) {
        // Get sample position
        vec3 sample_pos = tbn * samples[i]; // From tangent to view-space
        sample_pos = pos + sample_pos * radius;

        // Project sample position (to sample texture) (to get position on screen/texture)
        vec4 offset = vec4(sample_pos, 1);
        offset = projection * offset; // From view to clip-space
        offset.xyz /= offset.w; // Perspective divide
        offset.xyz = offset.xyz * 0.5 + 0.5; // Transform to range 0...1

        float sample_depth = texture(g_pos, offset.xy).z; // Get depth value of kernel sample
        float range_check = smoothstep(0, 1, radius / abs(pos.z - sample_depth));
        occ += (sample_depth >= sample_pos.z + bias ? 1 : 0) * range_check;
        // occ += (sample_depth >= sample_pos.z + sample_depth / 100 ? 1 : 0) * range_check;
        // occ += (sample_depth >= sample_pos.z + abs(sample_depth) / 1000 ? 1 : 0) * range_check;
    }
    colour = 1 - strength * occ / kernel_size;
}
