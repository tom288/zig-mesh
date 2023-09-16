#version 410 core

#define STEPS_MAX 64
#define DIST_MIN pow(2, -9)
#define VFOV 60.0
#define RAD 1.0

uniform vec3 POSITION;
uniform vec3 LOOK;
uniform vec3 RIGHT;
uniform vec3 ABOVE;
uniform float WIDTH;
uniform float HEIGHT;
uniform float POWER;

out vec4 colour;

vec3 rectilinear(float x, float y)
{
    float screen_dist = 1 / tan(radians(VFOV / 2));
    vec3 dir = LOOK * screen_dist - ABOVE * y;
    dir += RIGHT * x * float(WIDTH) / float(HEIGHT);
    return normalize(dir);
}

vec3 panorama(float x, float y)
{
    float hfov = VFOV * float(WIDTH) / float(HEIGHT);
    vec3 dir = vec3(1);
    dir.x = tan(x * radians(hfov / 2));
    dir.y = tan(y * radians(VFOV / 2));
    return normalize(dir);
}

// Solid sphere with negative interior
float DE1(vec3 p)
{
    return length(p) - RAD;
}

// Infinite plane of spheres
float DE2(vec3 p)
{
    p.x = mod(p.x + RAD, RAD * 2) - RAD;
    p.y = mod(p.y + RAD, RAD * 2) - RAD;
    return DE1(p);
}

// Infinite grid of spheres
float DE3(vec3 p)
{
    p.x = mod(p.x + RAD, RAD * 2) - RAD;
    p.y = mod(p.y + RAD, RAD * 2) - RAD;
    p.z = mod(p.z + RAD, RAD * 2) - RAD;
    return DE1(p) + 0.6;
}

// Mandelbulb
float DEM(vec3 pos)
{
    const float BAILOUT = 8;
    vec3 p = pos;
    float dr = 1;
    float r = 0;
    for (int i = 0; i < STEPS_MAX ; i++)
    {
        r = length(p);
        if (r > BAILOUT) break;

        // Convert to polar coordinates
        float theta = acos(p.z / r) * POWER;
        float phi = atan(p.y, p.x) * POWER;
        dr = pow(r, POWER - 1.0f) * POWER * dr + 1.0f;

        // Convert back to cartesian coordinates
        p = vec3(sin(theta) * cos(phi), sin(phi) * sin(theta), cos(theta));
        p *= pow(r, POWER);
        p += pos;
    }
    return 0.5 * log(r) * r / dr;
}

float trace(vec3 from, vec3 dir)
{
    float total_dist = 0.0;
    int steps;

    for (steps = 0; steps < STEPS_MAX; ++steps)
    {
        vec3 p = from + dir * total_dist;
        float dist = DEM(p);
        total_dist += dist;
        if (dist < DIST_MIN) break;
    }

    // TODO smooth iteration count
    return 1.0 - float(steps) / float(STEPS_MAX);
}

void main()
{
    float x = (gl_FragCoord.x * 2 + 1) / WIDTH  - 1.0;
    float y = (gl_FragCoord.y * 2 + 1) / HEIGHT - 1.0;
    vec3 dir = rectilinear(x, y);
    colour.rgb = vec3(trace(POSITION, dir));
}
