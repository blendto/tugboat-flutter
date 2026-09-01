#include "tugboat/tb_image_core.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

int g_failures = 0;

void check(bool cond, const char* expr, const char* file, int line) {
  if (!cond) {
    std::fprintf(stderr, "FAIL %s:%d %s\n", file, line, expr);
    ++g_failures;
  }
}

#define CHECK(cond) check(static_cast<bool>(cond), #cond, __FILE__, __LINE__)

std::vector<uint8_t> packed(int32_t width, int32_t height, uint8_t r, uint8_t g,
                            uint8_t b, uint8_t a) {
  std::vector<uint8_t> out(static_cast<size_t>(width) * height * 4);
  for (size_t i = 0; i < out.size(); i += 4) {
    out[i] = r;
    out[i + 1] = g;
    out[i + 2] = b;
    out[i + 3] = a;
  }
  return out;
}

tb_image_request_v1 make_request(std::vector<uint8_t>& pixels, int32_t width,
                                 int32_t height, tb_pixel_format format) {
  tb_image_request_v1 req{};
  req.abi_version = TB_IMAGE_CORE_ABI_VERSION;
  req.pixels = pixels.data();
  req.width = width;
  req.height = height;
  req.stride_bytes = width * 4;
  req.format = format;
  req.masks = nullptr;
  req.mask_count = 0;
  req.last_dhash = nullptr;
  req.force = 0;
  return req;
}

void test_version() {
  CHECK(std::strcmp(tb_image_core_version(), "0.1.0") == 0);
  CHECK(tb_image_core_abi_version() == TB_IMAGE_CORE_ABI_VERSION);
}

void test_zero_size() {
  std::vector<uint8_t> pixels(16, 128);
  tb_image_result_v1 result{};
  auto req = make_request(pixels, 0, 8, TB_PIXEL_FORMAT_RGBA8888);
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_INVALID_ARGUMENT);
  CHECK(result.dhash[0] == '\0');

  req = make_request(pixels, 8, 0, TB_PIXEL_FORMAT_RGBA8888);
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_INVALID_ARGUMENT);
}

void test_invalid_stride() {
  auto pixels = packed(8, 8, 128, 128, 128, 255);
  tb_image_result_v1 result{};
  auto req = make_request(pixels, 8, 8, TB_PIXEL_FORMAT_RGBA8888);
  req.stride_bytes = 8 * 4 - 1;
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_INVALID_ARGUMENT);

  req.stride_bytes = 0;
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_INVALID_ARGUMENT);
}

void test_integer_overflow() {
  std::vector<uint8_t> pixels(4, 0);
  tb_image_result_v1 result{};
  auto req = make_request(pixels, 8, 8, TB_PIXEL_FORMAT_RGBA8888);
  req.width = INT32_MAX;
  req.height = 8;
  req.stride_bytes = INT32_MAX;
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_INVALID_ARGUMENT);

  req = make_request(pixels, 8, 8, TB_PIXEL_FORMAT_RGBA8888);
  req.width = 1 << 16;
  req.height = 1 << 16;
  req.stride_bytes = 1 << 18;
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_IMAGE_TOO_LARGE);

  req = make_request(pixels, 8, 8, TB_PIXEL_FORMAT_RGBA8888);
  req.width = 4097;
  req.height = 4096;
  req.stride_bytes = 4097 * 4;
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_IMAGE_TOO_LARGE);
}

void test_too_large_and_unsupported() {
  auto pixels = packed(8, 8, 1, 2, 3, 255);
  tb_image_result_v1 result{};
  auto req = make_request(pixels, 8, 8, TB_PIXEL_FORMAT_RGBA8888);
  req.width = TB_IMAGE_CORE_MAX_WIDTH + 1;
  req.stride_bytes = req.width * 4;
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_IMAGE_TOO_LARGE);

  req = make_request(pixels, 8, 8, static_cast<tb_pixel_format>(99));
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_UNSUPPORTED_FORMAT);

  CHECK(tb_image_process_v1(nullptr, &result) == TB_IMAGE_INVALID_ARGUMENT);
  req = make_request(pixels, 8, 8, TB_PIXEL_FORMAT_RGBA8888);
  req.abi_version = 0;
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_INVALID_ARGUMENT);
  req = make_request(pixels, 8, 8, TB_PIXEL_FORMAT_RGBA8888);
  req.mask_count = 1;
  req.masks = nullptr;
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_INVALID_ARGUMENT);
  CHECK(tb_image_process_v1(&req, nullptr) == TB_IMAGE_INVALID_ARGUMENT);
}

void test_mask_clip_and_empty() {
  auto pixels = packed(8, 8, 200, 0, 0, 255);
  tb_rect masks[] = {
      {-4, -4, 2, 2},
      {6, 6, 100, 100},
      {3, 3, 3, 7},
      {5, 1, 4, 4},
  };
  tb_image_result_v1 result{};
  auto req = make_request(pixels, 8, 8, TB_PIXEL_FORMAT_RGBA8888);
  req.masks = masks;
  req.mask_count = 4;
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);

  auto at = [&](int x, int y) { return &pixels[(y * 8 + x) * 4]; };
  CHECK(at(0, 0)[0] == 0x1a && at(0, 0)[3] == 0xff);
  CHECK(at(1, 1)[0] == 0x1a);
  CHECK(at(2, 2)[0] == 200);
  CHECK(at(6, 6)[0] == 0x1a);
  CHECK(at(7, 7)[0] == 0x1a);
  CHECK(at(5, 5)[0] == 200);
  CHECK(at(3, 3)[0] == 200);
}

void test_overlapping_masks() {
  auto pixels = packed(4, 4, 9, 9, 9, 255);
  tb_rect masks[] = {{0, 0, 3, 3}, {1, 1, 4, 4}};
  tb_image_result_v1 result{};
  auto req = make_request(pixels, 4, 4, TB_PIXEL_FORMAT_RGBA8888);
  req.masks = masks;
  req.mask_count = 2;
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
  CHECK(pixels[(0 * 4 + 0) * 4] == 0x1a);
  CHECK(pixels[(3 * 4 + 3) * 4] == 0x1a);
  CHECK(pixels[(0 * 4 + 3) * 4] == 9);
}

void test_rgba_and_bgra_masks() {
  auto rgba = packed(4, 2, 255, 0, 0, 255);
  tb_rect mask{0, 0, 2, 2};
  tb_image_result_v1 result{};
  auto req = make_request(rgba, 4, 2, TB_PIXEL_FORMAT_RGBA8888);
  req.masks = &mask;
  req.mask_count = 1;
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
  CHECK(rgba[0] == 0x1a && rgba[1] == 0x1a && rgba[2] == 0x1a &&
        rgba[3] == 0xff);
  CHECK(rgba[8] == 255);

  auto bgra = packed(4, 2, 0, 0, 255, 255);
  req = make_request(bgra, 4, 2, TB_PIXEL_FORMAT_BGRA8888);
  req.masks = &mask;
  req.mask_count = 1;
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
  CHECK(bgra[0] == 0x1a && bgra[2] == 0x1a && bgra[3] == 0xff);
  CHECK(bgra[8] == 0);
}

void test_dhash_goldens() {
  /* Captured from Dart computeDHashFromRgba on 2026-08-31. */
  tb_image_result_v1 result{};

  auto uniform = packed(8, 8, 128, 128, 128, 128);
  auto req = make_request(uniform, 8, 8, TB_PIXEL_FORMAT_RGBA8888);
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
  CHECK(std::strcmp(result.dhash,
                    "0000000000000000000000000000000000000000000000000000000000"
                    "000000") == 0);

  auto uniform200 = packed(80, 80, 200, 200, 200, 200);
  req = make_request(uniform200, 80, 80, TB_PIXEL_FORMAT_RGBA8888);
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
  CHECK(std::strlen(result.dhash) == 64);
  CHECK(std::strspn(result.dhash, "0") == 64);

  std::vector<uint8_t> corner(80 * 80 * 4);
  for (int y = 0; y < 80; ++y) {
    for (int x = 0; x < 80; ++x) {
      const int offset = (y * 80 + x) * 4;
      const uint8_t gray = (x < 10 && y < 10) ? 0 : 200;
      corner[offset] = gray;
      corner[offset + 1] = gray;
      corner[offset + 2] = gray;
      corner[offset + 3] = 255;
    }
  }
  req = make_request(corner, 80, 80, TB_PIXEL_FORMAT_RGBA8888);
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
  CHECK(std::strcmp(result.dhash,
                    "1100000000000000000000000000000000000000000000000000000000"
                    "000000") == 0);

  std::vector<uint8_t> grad(32 * 16 * 4);
  for (int y = 0; y < 16; ++y) {
    for (int x = 0; x < 32; ++x) {
      const int o = (y * 32 + x) * 4;
      grad[o] = static_cast<uint8_t>(x * 8);
      grad[o + 1] = 0;
      grad[o + 2] = static_cast<uint8_t>(255 - x * 8);
      grad[o + 3] = 255;
    }
  }
  req = make_request(grad, 32, 16, TB_PIXEL_FORMAT_RGBA8888);
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
  CHECK(std::strspn(result.dhash, "1") == 64);

  auto one = packed(1, 1, 10, 20, 30, 255);
  req = make_request(one, 1, 1, TB_PIXEL_FORMAT_RGBA8888);
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
  CHECK(std::strspn(result.dhash, "0") == 64);

  std::vector<uint8_t> grid(9 * 8 * 4);
  for (int y = 0; y < 8; ++y) {
    for (int x = 0; x < 9; ++x) {
      const int o = (y * 9 + x) * 4;
      const uint8_t v = static_cast<uint8_t>((x + y) * 15);
      grid[o] = v;
      grid[o + 1] = v;
      grid[o + 2] = v;
      grid[o + 3] = 255;
    }
  }
  req = make_request(grid, 9, 8, TB_PIXEL_FORMAT_RGBA8888);
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
  CHECK(std::strspn(result.dhash, "1") == 64);

  std::vector<uint8_t> chk(16 * 16 * 4);
  for (int y = 0; y < 16; ++y) {
    for (int x = 0; x < 16; ++x) {
      const int o = (y * 16 + x) * 4;
      const uint8_t v = (((x / 2) + (y / 2)) % 2 == 0) ? 0 : 255;
      chk[o] = v;
      chk[o + 1] = v;
      chk[o + 2] = v;
      chk[o + 3] = 255;
    }
  }
  req = make_request(chk, 16, 16, TB_PIXEL_FORMAT_RGBA8888);
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
  CHECK(std::strcmp(result.dhash,
                    "1001010100001010100101010000101010010101000010101001010100"
                    "001010") == 0);
}

void test_bgra_dhash_matches_rgba() {
  auto rgba = packed(16, 8, 255, 0, 0, 255);
  auto bgra = packed(16, 8, 0, 0, 255, 255);
  tb_image_result_v1 rgba_result{};
  tb_image_result_v1 bgra_result{};
  auto req = make_request(rgba, 16, 8, TB_PIXEL_FORMAT_RGBA8888);
  CHECK(tb_image_process_v1(&req, &rgba_result) == TB_IMAGE_OK);
  req = make_request(bgra, 16, 8, TB_PIXEL_FORMAT_BGRA8888);
  CHECK(tb_image_process_v1(&req, &bgra_result) == TB_IMAGE_OK);
  CHECK(std::strcmp(rgba_result.dhash, bgra_result.dhash) == 0);
}

void test_hamming_and_force() {
  auto pixels = packed(8, 8, 128, 128, 128, 255);
  tb_image_result_v1 result{};
  auto req = make_request(pixels, 8, 8, TB_PIXEL_FORMAT_RGBA8888);
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
  const std::string original = result.dhash;

  std::string two = original;
  two[0] = two[0] == '0' ? '1' : '0';
  two[1] = two[1] == '0' ? '1' : '0';
  req.last_dhash = two.c_str();
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_SKIPPED_BY_DHASH);

  std::string three = two;
  three[2] = three[2] == '0' ? '1' : '0';
  req.last_dhash = three.c_str();
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);

  req.last_dhash = two.c_str();
  req.force = 1;
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);

  req.force = 0;
  req.last_dhash = "";
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
  req.last_dhash = "01";
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
  req.last_dhash = "not-a-valid-dhash";
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
}

void test_deterministic_and_timings() {
  auto a = packed(32, 32, 40, 80, 120, 255);
  auto b = packed(32, 32, 40, 80, 120, 255);
  tb_image_result_v1 first{};
  tb_image_result_v1 second{};
  auto req_a = make_request(a, 32, 32, TB_PIXEL_FORMAT_RGBA8888);
  auto req_b = make_request(b, 32, 32, TB_PIXEL_FORMAT_RGBA8888);
  CHECK(tb_image_process_v1(&req_a, &first) == TB_IMAGE_OK);
  CHECK(tb_image_process_v1(&req_b, &second) == TB_IMAGE_OK);
  CHECK(std::strcmp(first.dhash, second.dhash) == 0);
  CHECK(first.mask_fill_micros >= 0);
  CHECK(first.dhash_micros >= 0);
  CHECK(std::strlen(first.dhash) == 64);
}

void test_padded_stride() {
  const int32_t width = 4;
  const int32_t height = 2;
  const int32_t stride = 32;
  std::vector<uint8_t> pixels(static_cast<size_t>(stride) * height, 7);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      uint8_t* px = pixels.data() + y * stride + x * 4;
      px[0] = 200;
      px[1] = 200;
      px[2] = 200;
      px[3] = 255;
    }
  }
  tb_rect mask{0, 0, 1, 1};
  tb_image_result_v1 result{};
  tb_image_request_v1 req{};
  req.abi_version = TB_IMAGE_CORE_ABI_VERSION;
  req.pixels = pixels.data();
  req.width = width;
  req.height = height;
  req.stride_bytes = stride;
  req.format = TB_PIXEL_FORMAT_RGBA8888;
  req.masks = &mask;
  req.mask_count = 1;
  CHECK(tb_image_process_v1(&req, &result) == TB_IMAGE_OK);
  CHECK(pixels[0] == 0x1a);
  CHECK(pixels[16] == 7);
}

}  // namespace

int main() {
  test_version();
  test_zero_size();
  test_invalid_stride();
  test_integer_overflow();
  test_too_large_and_unsupported();
  test_mask_clip_and_empty();
  test_overlapping_masks();
  test_rgba_and_bgra_masks();
  test_dhash_goldens();
  test_bgra_dhash_matches_rgba();
  test_hamming_and_force();
  test_deterministic_and_timings();
  test_padded_stride();
  if (g_failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", g_failures);
    return 1;
  }
  std::puts("ok");
  return 0;
}
