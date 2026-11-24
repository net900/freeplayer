package cn.freeplayer.app.bvc2;

import android.os.Handler;
import android.util.Log;
import android.view.Surface;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.decoder.CryptoConfig;
import androidx.media3.decoder.Decoder;
import androidx.media3.decoder.DecoderException;
import androidx.media3.decoder.DecoderInputBuffer;
import androidx.media3.decoder.VideoDecoderOutputBuffer;
import androidx.media3.exoplayer.RendererCapabilities;
import androidx.media3.exoplayer.video.DecoderVideoRenderer;
import androidx.media3.exoplayer.video.VideoRendererEventListener;

/** Media3 video renderer for the vendor ByteVC2 decoder. */
public final class Bvc2VideoRenderer extends DecoderVideoRenderer {
  public Bvc2VideoRenderer(Handler handler, VideoRendererEventListener listener) {
    super(5000, handler, listener, 50);
  }

  @Override
  public String getName() {
    return "FreePlayer BVC2";
  }

  @Override
  public int supportsFormat(Format format) {
    if (!"video/x-bytevc2".equals(format.sampleMimeType)) {
      return RendererCapabilities.create(C.FORMAT_UNSUPPORTED_TYPE);
    }
    if (!Bvc2Native.isAvailable() || format.cryptoType != C.CRYPTO_TYPE_NONE) {
      return RendererCapabilities.create(C.FORMAT_UNSUPPORTED_SUBTYPE);
    }
    return RendererCapabilities.create(
        C.FORMAT_HANDLED,
        RendererCapabilities.ADAPTIVE_NOT_SEAMLESS,
        RendererCapabilities.TUNNELING_NOT_SUPPORTED);
  }

  @Override
  protected Decoder<DecoderInputBuffer, ? extends VideoDecoderOutputBuffer,
          ? extends DecoderException>
      createDecoder(Format format, CryptoConfig cryptoConfig) throws DecoderException {
    if (format.initializationData.isEmpty()) {
      throw new DecoderException("Missing BVC2 configuration");
    }
    return new Bvc2Decoder(format.initializationData.get(0));
  }

  private int renderLogged;

  @Override
  protected void renderOutputBufferToSurface(
      VideoDecoderOutputBuffer output, Surface surface) throws DecoderException {
    if (renderLogged < 5) {
      renderLogged++;
      Log.d(
          "FreePlayerBvc2",
          "render " + output.width + "x" + output.height + " mode=" + output.mode
              + " size=" + (output.data == null ? -1 : output.data.capacity()));
    }
    try {
      Bvc2Native.render(
          output.data,
          output.width,
          output.height,
          output.colorspace,
          output.decoderPrivate != 0,
          surface);
    } catch (RuntimeException | LinkageError error) {
      throw new DecoderException("BVC2 surface render failed", error);
    } finally {
      output.release();
    }
  }

  @Override
  protected void setDecoderOutputMode(int mode) {
    // Frames are written into Media3's existing output surface.
  }
}
