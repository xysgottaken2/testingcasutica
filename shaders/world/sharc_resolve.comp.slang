// Post-trace SHaRC resolve. One invocation owns one cache entry, so temporal history and stale-slot
// recycling never race. The host places a full Vulkan memory barrier before and after this dispatch.
import world_common;
import sharc;

struct SharcResolvePush {
    uint64_t worldPushAddr;
};

[[vk::push_constant]] SharcResolvePush resolvePush;

[shader("compute")]
[numthreads(256, 1, 1)]
void main(uint3 dispatchId : SV_DispatchThreadID) {
    WorldPush push = ConstPtr<WorldPush>(resolvePush.worldPushAddr)[0];
    sharcResolveEntry(push, dispatchId.x);
}
