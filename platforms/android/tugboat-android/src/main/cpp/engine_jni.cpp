// Thin JNI bridge over the session engine C ABI
// (core/session-engine/include/tugboat/tb_session_engine.h).
//
// No Java exception ever escapes these functions: every failure is a status
// code or a zero handle, and any pending exception is cleared before return.
#include "tugboat/tb_session_engine.h"

#include <jni.h>

#include <cstdint>

namespace {

jclass g_response_class = nullptr;
jmethodID g_response_ctor = nullptr;

tb_session_engine* from_handle(jlong handle) {
  return reinterpret_cast<tb_session_engine*>(static_cast<intptr_t>(handle));
}

bool clear_exception(JNIEnv* env) {
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    return true;
  }
  return false;
}

// Copies the engine-owned response into a new Java byte[]. The C buffer is
// only valid until the next submit or destroy on the handle.
jobject make_response(JNIEnv* env, tb_session_status status, const char* json,
                      size_t len) {
  if (json == nullptr) {
    len = 0;
  }
  jbyteArray bytes = env->NewByteArray(static_cast<jsize>(len));
  if (bytes == nullptr) {
    clear_exception(env);
    return nullptr;
  }
  if (len > 0) {
    env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(len),
                            reinterpret_cast<const jbyte*>(json));
  }
  jobject response = env->NewObject(g_response_class, g_response_ctor,
                                    static_cast<jint>(status), bytes);
  env->DeleteLocalRef(bytes);
  if (clear_exception(env)) {
    return nullptr;
  }
  return response;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /* reserved */) {
  JNIEnv* env = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    return JNI_ERR;
  }
  jclass local = env->FindClass("com/tugboat/android/engine/EngineResponse");
  if (local == nullptr) {
    clear_exception(env);
    return JNI_ERR;
  }
  g_response_class = static_cast<jclass>(env->NewGlobalRef(local));
  env->DeleteLocalRef(local);
  if (g_response_class == nullptr) {
    clear_exception(env);
    return JNI_ERR;
  }
  g_response_ctor = env->GetMethodID(g_response_class, "<init>", "(I[B)V");
  if (g_response_ctor == nullptr) {
    clear_exception(env);
    return JNI_ERR;
  }
  return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_tugboat_android_engine_NativeEngine_create(JNIEnv* /* env */,
                                                    jobject /* thiz */,
                                                    jint max_depth,
                                                    jlong max_message_bytes) {
  if (max_depth < 0 || max_message_bytes < 0) {
    return 0;
  }
  tb_session_engine_config_v1 config{};
  config.abi_version = TB_SESSION_ENGINE_ABI_VERSION;
  config.max_depth = static_cast<uint32_t>(max_depth);
  config.max_message_bytes = static_cast<size_t>(max_message_bytes);
  tb_session_engine* engine = nullptr;
  if (tb_session_engine_create_v1(&config, &engine) != TB_SESSION_OK) {
    return 0;
  }
  return static_cast<jlong>(reinterpret_cast<intptr_t>(engine));
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_tugboat_android_engine_NativeEngine_submit(JNIEnv* env,
                                                    jobject /* thiz */,
                                                    jlong handle,
                                                    jbyteArray message) {
  const jsize length = message == nullptr ? 0 : env->GetArrayLength(message);
  jbyte* bytes = nullptr;
  if (length > 0) {
    bytes = env->GetByteArrayElements(message, nullptr);
    if (bytes == nullptr) {
      clear_exception(env);
      return nullptr;
    }
  }
  const char* out = nullptr;
  size_t out_len = 0;
  const tb_session_status status = tb_session_engine_submit_v1(
      from_handle(handle), reinterpret_cast<const char*>(bytes),
      static_cast<size_t>(length), &out, &out_len);
  if (bytes != nullptr) {
    env->ReleaseByteArrayElements(message, bytes, JNI_ABORT);
  }
  return make_response(env, status, out, out_len);
}

extern "C" JNIEXPORT void JNICALL
Java_com_tugboat_android_engine_NativeEngine_destroy(JNIEnv* /* env */,
                                                     jobject /* thiz */,
                                                     jlong handle) {
  tb_session_engine_destroy(from_handle(handle));
}
