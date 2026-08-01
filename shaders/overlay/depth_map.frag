#version 460

layout(binding = 0) uniform sampler2D depthSource;

layout(push_constant) uniform Push {
    float nearPlane;
    float farPlane;
} pc;

void main() {
    ivec2 pix = ivec2(gl_FragCoord.xy);
    float linearDepth = texelFetch(depthSource, pix, 0).r;
    
    if (linearDepth >= 10000.0) {
        gl_FragDepth = 0.0; // reversed-Z far plane
    } else {
        gl_FragDepth = pc.nearPlane / linearDepth;
    }
}
