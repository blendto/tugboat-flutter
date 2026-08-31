# GPU processing roadmap

Do not start this work before the CPU device benchmark in
[cpu-capture-results.md](../performance/cpu-capture-results.md) is filled.

A GPU mask followed by a full CPU readback will not justify the extra
surface. GPU work only pays off when capture pixels stay in a Metal texture
or an Android GPU buffer through mask and reduced-luminance dHash.

Keep the C ABI stable. Keep the CPU path as fallback. Prototype Metal on
Apple and Vulkan (vs OpenGL ES compute) on Android only after the largest
remaining CPU stage is identified from device numbers.

See ADR [0007](../decisions/0007-gpu-deferred.md).
