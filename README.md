# TinyGPU-Cache
Files changed for per-core L1 cache support

1. src/l1_data_cache.sv
   - Implements the per-core cache itself.
   - Direct-mapped, write-through, write-allocate.
   - Tracks accesses, hits, misses.

2. src/core.sv
   - Routes all LSU accesses through the L1 cache.
   - Exposes per-core cache statistics.

3. src/gpu.sv
   - Propagates per-core cache statistics to the top level.
   - Keeps one cache-facing data-memory port per core.

4. README.md
   - Documents the cache at a high level.

5. docs/l1_cache_design.md
   - Describes design choices and evaluation methodology.

Recommended default config
- L1_CACHE_SIZE_BYTES = 64
- L1_CACHE_LINE_SIZE_BYTES = 8
- Organization = direct-mapped
- Replacement = overwrite on conflict (direct-mapped)
- Write policy = write-through + write-allocate
