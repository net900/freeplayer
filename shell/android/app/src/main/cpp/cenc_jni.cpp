// JNI adapter for the portable CENC core. The desktop client binds the same
// fp_cenc_* exports through dart:ffi; on Android the Media3 DataSource calls
// them from Kotlin instead, so it can decrypt samples inside the player
// process without a loopback HTTP proxy.

#include <jni.h>
#include <cstdint>

extern "C" {
const char* fp_cenc_last_error();
void* fp_cenc_index_create(const uint8_t* data, int32_t len, int64_t base,
                           int64_t fileSize);
void fp_cenc_index_free(void* handle);
int32_t fp_cenc_index_span(void* handle, int64_t start, int64_t end,
                           int64_t* lo, int64_t* hi);
int32_t fp_cenc_decrypt(void* handle, const uint8_t* key, int32_t keyLen,
                        uint8_t* buf, int32_t len, int64_t start);
}

extern "C" JNIEXPORT jlong JNICALL
Java_cn_freeplayer_app_cenc_CencNative_nativeIndexCreate(
    JNIEnv* env, jobject, jbyteArray data, jlong base, jlong fileSize) {
  if (data == nullptr) return 0;
  const jsize size = env->GetArrayLength(data);
  jbyte* bytes = env->GetByteArrayElements(data, nullptr);
  if (bytes == nullptr) return 0;
  void* handle = fp_cenc_index_create(
      reinterpret_cast<const uint8_t*>(bytes), size, base, fileSize);
  env->ReleaseByteArrayElements(data, bytes, JNI_ABORT);
  return reinterpret_cast<jlong>(handle);
}

extern "C" JNIEXPORT jint JNICALL
Java_cn_freeplayer_app_cenc_CencNative_nativeIndexSpan(
    JNIEnv* env, jobject, jlong handle, jlong start, jlong end,
    jlongArray out) {
  if (out == nullptr || env->GetArrayLength(out) < 2) return -1;
  int64_t lo = start;
  int64_t hi = end;
  const jint result = fp_cenc_index_span(reinterpret_cast<void*>(handle),
                                         start, end, &lo, &hi);
  if (result != 0) return result;
  const jlong values[2] = {static_cast<jlong>(lo), static_cast<jlong>(hi)};
  env->SetLongArrayRegion(out, 0, 2, values);
  return 0;
}

extern "C" JNIEXPORT jint JNICALL
Java_cn_freeplayer_app_cenc_CencNative_nativeDecrypt(
    JNIEnv* env, jobject, jlong handle, jbyteArray key, jbyteArray buffer,
    jlong start) {
  if (key == nullptr || buffer == nullptr) return -1;
  const jsize keySize = env->GetArrayLength(key);
  const jsize bufferSize = env->GetArrayLength(buffer);
  if (keySize <= 0 || bufferSize <= 0) return -1;
  jbyte* keyBytes = env->GetByteArrayElements(key, nullptr);
  jbyte* bufferBytes = env->GetByteArrayElements(buffer, nullptr);
  if (keyBytes == nullptr || bufferBytes == nullptr) {
    if (keyBytes != nullptr) {
      env->ReleaseByteArrayElements(key, keyBytes, JNI_ABORT);
    }
    if (bufferBytes != nullptr) {
      env->ReleaseByteArrayElements(buffer, bufferBytes, JNI_ABORT);
    }
    return -1;
  }
  const jint result = fp_cenc_decrypt(
      reinterpret_cast<void*>(handle),
      reinterpret_cast<const uint8_t*>(keyBytes), keySize,
      reinterpret_cast<uint8_t*>(bufferBytes), bufferSize, start);
  // On success copy the decrypted bytes back into the Java array; on failure
  // leave it untouched.
  env->ReleaseByteArrayElements(buffer, bufferBytes, result == 0 ? 0 : JNI_ABORT);
  env->ReleaseByteArrayElements(key, keyBytes, JNI_ABORT);
  return result;
}

extern "C" JNIEXPORT void JNICALL
Java_cn_freeplayer_app_cenc_CencNative_nativeIndexFree(JNIEnv*, jobject,
                                                       jlong handle) {
  if (handle != 0) fp_cenc_index_free(reinterpret_cast<void*>(handle));
}

extern "C" JNIEXPORT jstring JNICALL
Java_cn_freeplayer_app_cenc_CencNative_nativeIndexError(JNIEnv* env, jobject) {
  return env->NewStringUTF(fp_cenc_last_error());
}
