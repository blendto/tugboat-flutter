#include "tugboat/tb_image_core.h"

#include <android/bitmap.h>
#include <jni.h>

#include <vector>

namespace {

void release_if_needed(JNIEnv* env, jstring value, const char* chars) {
  if (value != nullptr && chars != nullptr) {
    env->ReleaseStringUTFChars(value, chars);
  }
}

}  // namespace

extern "C" JNIEXPORT jobject JNICALL
Java_com_tugboat_capture_internal_ImageCore_process(
    JNIEnv* env, jobject /* thiz */, jobject bitmap, jintArray masks_packed,
    jstring last_dhash, jboolean force) {
  jclass result_cls =
      env->FindClass("com/tugboat/capture/internal/NativeProcessResult");
  jmethodID result_ctor =
      env->GetMethodID(result_cls, "<init>", "(ILjava/lang/String;JJ)V");

  auto fail = [&](tb_image_status status) {
    return env->NewObject(result_cls, result_ctor, static_cast<jint>(status),
                          env->NewStringUTF(""), static_cast<jlong>(0),
                          static_cast<jlong>(0));
  };

  if (bitmap == nullptr) {
    return fail(TB_IMAGE_INVALID_ARGUMENT);
  }

  AndroidBitmapInfo info;
  if (AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS) {
    return fail(TB_IMAGE_INTERNAL_ERROR);
  }
  if (info.format != ANDROID_BITMAP_FORMAT_RGBA_8888) {
    return fail(TB_IMAGE_UNSUPPORTED_FORMAT);
  }

  void* pixels = nullptr;
  if (AndroidBitmap_lockPixels(env, bitmap, &pixels) !=
      ANDROID_BITMAP_RESULT_SUCCESS) {
    return fail(TB_IMAGE_INTERNAL_ERROR);
  }

  jobject java_result = nullptr;
  try {
    std::vector<tb_rect> rects;
    if (masks_packed != nullptr) {
      const jsize n = env->GetArrayLength(masks_packed);
      if (n % 4 != 0) {
        AndroidBitmap_unlockPixels(env, bitmap);
        return fail(TB_IMAGE_INVALID_ARGUMENT);
      }
      jint* packed = env->GetIntArrayElements(masks_packed, nullptr);
      if (packed != nullptr) {
        rects.resize(static_cast<size_t>(n / 4));
        for (jsize i = 0; i < n; i += 4) {
          tb_rect& r = rects[static_cast<size_t>(i / 4)];
          r.left = packed[i];
          r.top = packed[i + 1];
          r.right = packed[i + 2];
          r.bottom = packed[i + 3];
        }
        env->ReleaseIntArrayElements(masks_packed, packed, JNI_ABORT);
      }
    }

    const char* last_chars =
        last_dhash == nullptr ? nullptr
                              : env->GetStringUTFChars(last_dhash, nullptr);

    tb_image_request_v1 request{};
    request.abi_version = TB_IMAGE_CORE_ABI_VERSION;
    request.pixels = static_cast<uint8_t*>(pixels);
    request.width = static_cast<int32_t>(info.width);
    request.height = static_cast<int32_t>(info.height);
    request.stride_bytes = static_cast<int32_t>(info.stride);
    request.format = TB_PIXEL_FORMAT_RGBA8888;
    request.masks = rects.empty() ? nullptr : rects.data();
    request.mask_count = rects.size();
    request.last_dhash = last_chars;
    request.force = force == JNI_TRUE ? 1 : 0;

    tb_image_result_v1 native{};
    tb_image_process_v1(&request, &native);
    release_if_needed(env, last_dhash, last_chars);

    java_result = env->NewObject(
        result_cls, result_ctor, static_cast<jint>(native.status),
        env->NewStringUTF(native.dhash),
        static_cast<jlong>(native.mask_fill_micros),
        static_cast<jlong>(native.dhash_micros));
  } catch (...) {
    java_result = fail(TB_IMAGE_INTERNAL_ERROR);
  }

  AndroidBitmap_unlockPixels(env, bitmap);
  return java_result;
}
