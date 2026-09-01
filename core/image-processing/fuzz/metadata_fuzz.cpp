#include "tugboat/tb_image_core.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (size < 16) {
    return 0;
  }

  int32_t width = 0;
  int32_t height = 0;
  int32_t stride = 0;
  uint32_t abi = 0;
  std::memcpy(&width, data, 4);
  std::memcpy(&height, data + 4, 4);
  std::memcpy(&stride, data + 8, 4);
  std::memcpy(&abi, data + 12, 4);

  constexpr size_t kMaxBytes = 65536;
  std::vector<uint8_t> pixels(4, 0);
  bool sized = false;
  if (width > 0 && height > 0 && stride > 0) {
    const uint64_t min_stride = static_cast<uint64_t>(width) * 4u;
    const uint64_t stride_u = static_cast<uint64_t>(stride);
    const uint64_t height_u = static_cast<uint64_t>(height);
    if (stride_u >= min_stride &&
        height_u <= std::numeric_limits<uint64_t>::max() / stride_u) {
      const uint64_t bytes = stride_u * height_u;
      if (bytes <= kMaxBytes) {
        pixels.assign(static_cast<size_t>(bytes), 0);
        const size_t copy = std::min(static_cast<size_t>(bytes), size);
        std::memcpy(pixels.data(), data, copy);
        sized = true;
      }
    }
  }
  if (!sized) {
    width = 0;
  }

  tb_image_request_v1 req{};
  req.abi_version = abi;
  req.pixels = pixels.data();
  req.width = width;
  req.height = height;
  req.stride_bytes = stride;
  req.format = static_cast<tb_pixel_format>(data[12] % 5);
  req.mask_count = 0;
  req.masks = nullptr;
  req.last_dhash = (data[14] & 1) != 0 ? "not-a-valid-dhash" : nullptr;
  req.force = data[15] & 1;

  tb_image_result_v1 result{};
  tb_image_process_v1(&req, &result);
  tb_image_process_v1(nullptr, &result);
  tb_image_process_v1(&req, nullptr);
  return 0;
}
