# C++ image-processing core

Portable CPU core for privacy masks, buffer validation, dHash, and skip
decisions. Public surface is a versioned C ABI
(`include/tugboat/tb_image_core.h`).

Do not copy this tree into a pub package.

## Limits

- Language: C++17
- Width / height: 1..8192
- Pixel count: `width * height` ≤ 16,777,216
- Formats: RGBA8888, BGRA8888
- Stride: at least `width * 4` bytes
- dHash: 9×8, Hamming ≤ 2, matching
  `sdks/flutter/packages/tugboat/lib/src/perceptual_hash.dart`

See [repository-scope.md](../../docs/architecture/repository-scope.md) and
[native-capture-contracts.md](../../docs/architecture/native-capture-contracts.md).

## Build and test

```sh
cmake -S core/image-processing -B build/image-core \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_COMPILER=gcc \
  -DCMAKE_CXX_COMPILER=g++ \
  -DTB_IMAGE_CORE_SANITIZE=ON
cmake --build build/image-core
ctest --test-dir build/image-core --output-on-failure
```

Fuzzers (Clang):

```sh
cmake -S core/image-processing -B build/image-core-fuzz \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DTB_IMAGE_CORE_FUZZ=ON
cmake --build build/image-core-fuzz
./build/image-core-fuzz/tb_mask_fuzz -max_total_time=20
./build/image-core-fuzz/tb_metadata_fuzz -max_total_time=20
```
