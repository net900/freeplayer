package cn.freeplayer.app.bvc2;

import android.view.Surface;
import androidx.annotation.Keep;
import androidx.media3.decoder.VideoDecoderOutputBuffer;
import java.nio.ByteBuffer;

/** JNI surface around the vendor ByteVC2 decoder. */
@Keep
public final class Bvc2Native {
  private static final boolean loaded;

  static {
    boolean success;
    try {
      System.loadLibrary("freeplayer_bvc2");
      success = true;
    } catch (UnsatisfiedLinkError error) {
      success = false;
    }
    loaded = success;
  }

  private Bvc2Native() {}

  public static boolean isAvailable() {
    return loaded && available();
  }

  public static String getVersion() {
    return loaded ? version() : "";
  }

  static native boolean available();

  static native String version();

  static native long create(byte[] initializationData);

  static native boolean decode(
      long handle,
      ByteBuffer input,
      int offset,
      int size,
      long timeUs,
      VideoDecoderOutputBuffer output);

  static native void destroy(long handle);

  static native void render(
      ByteBuffer data,
      int width,
      int height,
      int color,
      boolean fullRange,
      Surface surface);
}
