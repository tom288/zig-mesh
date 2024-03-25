uint threadIndex() {
    const vec3 num_threads = gl_NumWorkGroups * gl_WorkGroupSize;
    return uint(dot(
        gl_GlobalInvocationID,
        vec3(1, num_threads.x, num_threads.y * num_threads.x)
    ));
}
