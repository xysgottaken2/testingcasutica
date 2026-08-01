import world_common;

[[vk::binding(0, 0)]] Sampler2D depthSource;

[[vk::push_constant]]
cbuffer Push {
    float nearPlane;
    float farPlane;
} pc;

[shader("fragment")]
void main(float4 position : SV_Position, out float depth : SV_Depth) {
    int2 pix = int2(position.xy);
    float linearDepth = depthSource.Load(int3(pix, 0)).x;
    
    if (linearDepth >= 10000.0) {
        depth = 0.0; // reversed-Z far plane
    } else {
        depth = pc.nearPlane / linearDepth;
    }
}
