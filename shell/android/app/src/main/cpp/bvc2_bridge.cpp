// JNI bridge to the ByteVC2 (VVC) software decoder shipped for Android.
//
// The vendor library exports a C API (byteVC2dec_*), not JNI. This bridge
// dlopens it on first use and adapts its packet/frame interface to Media3's
// DecoderVideoRenderer contract: decode into a VideoDecoderOutputBuffer, then
// convert the YUV planes to RGBA on the player's Texture surface.

#include <jni.h>
#include <android/log.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

namespace {

struct Api {
  void* lib = nullptr;
  void* (*getParam)() = nullptr;
  void* (*allocPacket)() = nullptr;
  void* (*allocFrame)() = nullptr;
  int (*setParamInt)(void*, const char*, int64_t) = nullptr;
  int (*setPacketInt)(void*, const char*, int64_t) = nullptr;
  int (*setPacketPtr)(void*, const char*, void*) = nullptr;
  void* (*create)(void*) = nullptr;
  void (*destroy)(void*) = nullptr;
  void (*releaseParam)(void*) = nullptr;
  void (*releasePacket)(void*) = nullptr;
  void (*releaseFrame)(void*) = nullptr;
  int (*decode)(void*, void*, void*) = nullptr;
  int64_t (*frameInt)(void*, const char*, int) = nullptr;
  void* (*framePtr)(void*, const char*, int) = nullptr;
  // The vendor fills a caller buffer with 8 bytes ("0.9.7.4"); it does not
  // return a pointer.
  void (*version)(char*) = nullptr;
};

Api api;
std::once_flag loadOnce;

bool load() {
  std::call_once(loadOnce, [] {
#if defined(__aarch64__) || defined(__arm__)
    api.lib = dlopen("libbyteVC2dec.so", RTLD_NOW | RTLD_LOCAL);
    if (!api.lib) return;
#define SYM(field, name) \
  api.field = reinterpret_cast<decltype(api.field)>(dlsym(api.lib, name))
    SYM(getParam, "byteVC2dec_get_default_param");
    SYM(allocPacket, "byteVC2dec_alloc_packet");
    SYM(allocFrame, "byteVC2dec_alloc_frame");
    SYM(setParamInt, "byteVC2dec_set_param_integer_info");
    SYM(setPacketInt, "byteVC2dec_set_packet_integer_info");
    SYM(setPacketPtr, "byteVC2dec_set_packet_pointer_info");
    SYM(create, "byteVC2dec_create");
    SYM(destroy, "byteVC2dec_destroy");
    SYM(releaseParam, "byteVC2dec_release_param");
    SYM(releasePacket, "byteVC2dec_release_packet");
    SYM(releaseFrame, "byteVC2dec_release_frame");
    SYM(decode, "byteVC2dec_decode");
    SYM(frameInt, "byteVC2dec_get_frame_integer_info");
    SYM(framePtr, "byteVC2dec_get_frame_pointer_info");
    SYM(version, "byteVC2dec_get_version");
#undef SYM
#endif
  });
  return api.getParam && api.allocPacket && api.allocFrame && api.setParamInt &&
         api.setPacketInt && api.setPacketPtr && api.create && api.destroy &&
         api.releaseParam && api.releasePacket && api.releaseFrame &&
         api.decode && api.frameInt && api.framePtr;
}

struct Decoder {
  void* params = nullptr;
  void* context = nullptr;
  void* packet = nullptr;
  void* frame = nullptr;
  std::vector<uint8_t> input;

  ~Decoder() {
    if (context) api.destroy(context);
    if (frame) api.releaseFrame(frame);
    if (packet) api.releasePacket(packet);
    if (params) api.releaseParam(params);
  }

  // Samples stay in their MP4 form: the vendor decoder consumes the
  // length-prefixed NAL units exactly as the container stores them.
  int feed(const uint8_t* bytes, int size, int64_t pts) {
    if (size > 0) {
      input.assign(bytes, bytes + size);
    } else {
      input.clear();
    }
    // The decoder's SIMD reads past the payload; give it zeroed tail padding
    // instead of pointing into a Java-owned buffer.
    input.resize(input.size() + 64, 0);
    api.setPacketPtr(packet, "bs", size > 0 ? input.data() : nullptr);
    api.setPacketInt(packet, "bs_len", size);
    api.setPacketInt(packet, "pts", pts);
    api.setPacketInt(packet, "flag", 0);
    const int result = api.decode(context, packet, frame);
    static int logged = 0;
    if (logged < 3) {
      logged++;
      __android_log_print(ANDROID_LOG_DEBUG, "FreePlayerBvc2",
                          "feed size=%d pts=%lld result=%d", size,
                          static_cast<long long>(pts), result);
    }
    return result;
  }
};

void throwError(JNIEnv* env, const char* message) {
  jclass cls = env->FindClass("java/lang/IllegalStateException");
  if (cls != nullptr) env->ThrowNew(cls, message);
}

int clampByte(int value) { return std::max(0, std::min(255, value)); }

int colorToMedia3(int colorSpace) {
  // 1 = BT.601, 2 = BT.709 in the vendor frame info.
  return colorSpace == 1 ? 2 : 1;
}

}  // namespace

extern "C" {

JNIEXPORT jboolean JNICALL
Java_cn_freeplayer_app_bvc2_Bvc2Native_available(JNIEnv*, jclass) {
  return load() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jstring JNICALL
Java_cn_freeplayer_app_bvc2_Bvc2Native_version(JNIEnv* env, jclass) {
  if (!load() || api.version == nullptr) return env->NewStringUTF("");
  char buffer[32] = {0};
  api.version(buffer);
  return env->NewStringUTF(buffer);
}

JNIEXPORT jlong JNICALL
Java_cn_freeplayer_app_bvc2_Bvc2Native_create(JNIEnv* env, jclass,
                                              jbyteArray config) {
  if (!load()) {
    throwError(env, "BVC2 decoder is unavailable on this ABI");
    return 0;
  }
  auto* decoder = new Decoder();
  decoder->params = api.getParam();
  if (decoder->params != nullptr) {
    api.setParamInt(decoder->params, "threads", 2);
    api.setParamInt(decoder->params, "parallel_frames", 1);
#if defined(__aarch64__)
    api.setParamInt(decoder->params, "gpu_mode", 0);
#endif
    api.setParamInt(decoder->params, "output_method", 0);
    api.setParamInt(decoder->params, "wpp_mode", 0);
    decoder->packet = api.allocPacket();
    decoder->frame = api.allocFrame();
    decoder->context = api.create(decoder->params);
  }
  if (decoder->params == nullptr || decoder->packet == nullptr ||
      decoder->frame == nullptr || decoder->context == nullptr) {
    delete decoder;
    throwError(env, "Could not initialize BVC2 decoder");
    return 0;
  }
  const int length = config == nullptr ? 0 : env->GetArrayLength(config);
  std::vector<uint8_t> init(static_cast<size_t>(length));
  if (length > 0) {
    env->GetByteArrayRegion(config, 0, length,
                            reinterpret_cast<jbyte*>(init.data()));
  }
  if (length > 0 && decoder->feed(init.data(), length, 0) != 0) {
    delete decoder;
    throwError(env, "Could not decode BVC2 configuration");
    return 0;
  }
  return reinterpret_cast<jlong>(decoder);
}

JNIEXPORT jboolean JNICALL
Java_cn_freeplayer_app_bvc2_Bvc2Native_decode(JNIEnv* env, jclass,
                                              jlong handle, jobject input,
                                              jint offset, jint size, jlong pts,
                                              jobject output) {
  auto* decoder = reinterpret_cast<Decoder*>(handle);
  if (decoder == nullptr || size < 0 || size > 16 * 1024 * 1024 ||
      offset < 0) {
    throwError(env, "Invalid BVC2 packet");
    return JNI_FALSE;
  }
  auto* bytes =
      input == nullptr
          ? nullptr
          : static_cast<uint8_t*>(env->GetDirectBufferAddress(input));
  if (size > 0 &&
      (bytes == nullptr ||
       static_cast<int64_t>(offset) + size >
           env->GetDirectBufferCapacity(input))) {
    throwError(env, "Invalid BVC2 input buffer");
    return JNI_FALSE;
  }
  if (decoder->feed(size > 0 ? bytes + offset : nullptr, size, pts) != 0) {
    throwError(env, "BVC2 packet decode failed");
    return JNI_FALSE;
  }
  if (!api.frameInt(decoder->frame, "got_frame", 0)) return JNI_FALSE;
  const int width = static_cast<int>(api.frameInt(decoder->frame, "width", 0));
  const int height =
      static_cast<int>(api.frameInt(decoder->frame, "height", 0));
  if (width <= 0 || height <= 0 || width > 4096 || height > 4096 ||
      api.frameInt(decoder->frame, "bit_depth", 0) != 8) {
    throwError(env, "Unsupported BVC2 frame dimensions or bit depth");
    return JNI_FALSE;
  }
  const int chromaWidth = (width + 1) / 2;
  const int chromaHeight = (height + 1) / 2;
  jclass cls = env->GetObjectClass(output);
  if (cls == nullptr || env->ExceptionCheck()) return JNI_FALSE;
  const int color =
      colorToMedia3(static_cast<int>(api.frameInt(decoder->frame, "color_space", 0)));
  jmethodID init = env->GetMethodID(cls, "initForYuvFrame", "(IIIII)Z");
  if (init == nullptr || env->ExceptionCheck()) {
    env->DeleteLocalRef(cls);
    return JNI_FALSE;
  }
  jfieldID dataField = env->GetFieldID(cls, "data", "Ljava/nio/ByteBuffer;");
  jfieldID timeField = env->GetFieldID(cls, "timeUs", "J");
  jfieldID rangeField = env->GetFieldID(cls, "decoderPrivate", "I");
  if (dataField == nullptr || timeField == nullptr || rangeField == nullptr ||
      env->ExceptionCheck()) {
    env->DeleteLocalRef(cls);
    return JNI_FALSE;
  }
  jboolean initialized = env->CallBooleanMethod(
      output, init, width, height, width, chromaWidth, color);
  if (env->ExceptionCheck()) {
    env->DeleteLocalRef(cls);
    return JNI_FALSE;
  }
  if (!initialized) {
    env->DeleteLocalRef(cls);
    throwError(env, "BVC2 frame allocation failed");
    return JNI_FALSE;
  }
  jobject data = env->GetObjectField(output, dataField);
  if (data == nullptr || env->ExceptionCheck()) {
    env->DeleteLocalRef(cls);
    return JNI_FALSE;
  }
  auto* target = static_cast<uint8_t*>(env->GetDirectBufferAddress(data));
  if (target == nullptr ||
      env->GetDirectBufferCapacity(data) <
          static_cast<int64_t>(width) * height +
              2LL * chromaWidth * chromaHeight) {
    env->DeleteLocalRef(data);
    env->DeleteLocalRef(cls);
    throwError(env, "Invalid BVC2 frame buffer");
    return JNI_FALSE;
  }
  for (int plane = 0; plane < 3; plane++) {
    auto* source =
        static_cast<uint8_t*>(api.framePtr(decoder->frame, "data", plane));
    const int stride = static_cast<int>(
        api.frameInt(decoder->frame, "linesize", plane));
    const int planeWidth = plane == 0 ? width : chromaWidth;
    const int planeHeight = plane == 0 ? height : chromaHeight;
    if (source == nullptr || stride < planeWidth) {
      env->DeleteLocalRef(data);
      env->DeleteLocalRef(cls);
      throwError(env, "Invalid BVC2 frame planes");
      return JNI_FALSE;
    }
    for (int row = 0; row < planeHeight; row++) {
      std::memcpy(target + static_cast<size_t>(row) * planeWidth,
                  source + static_cast<size_t>(row) * stride, planeWidth);
    }
    target += planeWidth * planeHeight;
  }
  env->SetLongField(output, timeField,
                    api.frameInt(decoder->frame, "pts", 0));
  env->SetIntField(output, rangeField,
                   api.frameInt(decoder->frame, "video_full_range_flag", 0)
                       ? 1
                       : 0);
  env->DeleteLocalRef(data);
  env->DeleteLocalRef(cls);
  return JNI_TRUE;
}

JNIEXPORT void JNICALL
Java_cn_freeplayer_app_bvc2_Bvc2Native_destroy(JNIEnv*, jclass, jlong handle) {
  delete reinterpret_cast<Decoder*>(handle);
}

JNIEXPORT void JNICALL
Java_cn_freeplayer_app_bvc2_Bvc2Native_render(JNIEnv* env, jclass,
                                              jobject data, jint width,
                                              jint height, jint color,
                                              jboolean fullRange,
                                              jobject surface) {
  auto* y = static_cast<uint8_t*>(env->GetDirectBufferAddress(data));
  const int chromaWidth = (width + 1) / 2;
  const int chromaHeight = (height + 1) / 2;
  if (y == nullptr || width <= 0 || height <= 0 || width > 4096 ||
      height > 4096 ||
      env->GetDirectBufferCapacity(data) <
          static_cast<int64_t>(width) * height +
              2LL * chromaWidth * chromaHeight) {
    throwError(env, "Invalid BVC2 output buffer");
    return;
  }
  auto* u = y + static_cast<size_t>(width) * height;
  auto* v = u + static_cast<size_t>(chromaWidth) * chromaHeight;
  static int renderLogged = 0;
  if (renderLogged < 1) {
    renderLogged++;
    __android_log_print(ANDROID_LOG_DEBUG, "FreePlayerBvc2",
                        "render %dx%d color=%d full=%d", width, height, color,
                        fullRange ? 1 : 0);
  }
  ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
  if (window == nullptr) {
    throwError(env, "BVC2 surface is unavailable");
    return;
  }
  // Reconfiguring the queue on every frame drops buffers on a
  // SurfaceTexture-backed surface, so only react to a new window or size.
  static ANativeWindow* geometryWindow = nullptr;
  static int geometryWidth = 0;
  static int geometryHeight = 0;
  if (window != geometryWindow || width != geometryWidth ||
      height != geometryHeight) {
    geometryWindow = window;
    geometryWidth = width;
    geometryHeight = height;
    ANativeWindow_setBuffersGeometry(window, width, height,
                                     WINDOW_FORMAT_RGBA_8888);
  }
  ANativeWindow_Buffer buffer;
  if (ANativeWindow_lock(window, &buffer, nullptr) != 0) {
    ANativeWindow_release(window);
    throwError(env, "Could not lock BVC2 surface");
    return;
  }
  const int cr = fullRange ? (color == 2 ? 403 : 359) : (color == 2 ? 459 : 409);
  const int gu = fullRange ? (color == 2 ? 48 : 88) : (color == 2 ? 55 : 100);
  const int gv = fullRange ? (color == 2 ? 120 : 183) : (color == 2 ? 136 : 208);
  const int cb = fullRange ? (color == 2 ? 475 : 454) : (color == 2 ? 541 : 516);
  for (int row = 0; row < height; row++) {
    auto* dest =
        static_cast<uint8_t*>(buffer.bits) + static_cast<size_t>(row) * buffer.stride * 4;
    const int chromaRow = row / 2;
    for (int x = 0; x < width; x++) {
      const int yy = y[static_cast<size_t>(row) * width + x];
      const int uu = u[static_cast<size_t>(chromaRow) * chromaWidth + x / 2] - 128;
      const int vv = v[static_cast<size_t>(chromaRow) * chromaWidth + x / 2] - 128;
      const int base = fullRange ? 256 * yy : 298 * std::max(0, yy - 16);
      dest[4 * x] = static_cast<uint8_t>(clampByte((base + cr * vv + 128) >> 8));
      dest[4 * x + 1] =
          static_cast<uint8_t>(clampByte((base - gu * uu - gv * vv + 128) >> 8));
      dest[4 * x + 2] =
          static_cast<uint8_t>(clampByte((base + cb * uu + 128) >> 8));
      dest[4 * x + 3] = 255;
    }
  }
  ANativeWindow_unlockAndPost(window);
  ANativeWindow_release(window);
}

}  // extern "C"
