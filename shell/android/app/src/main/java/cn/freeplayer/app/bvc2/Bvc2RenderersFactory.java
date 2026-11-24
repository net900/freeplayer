package cn.freeplayer.app.bvc2;

import android.content.Context;
import android.os.Handler;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.Renderer;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.video.VideoRendererEventListener;
import java.util.ArrayList;

/** Adds the ByteVC2 renderer after the default audio/video renderers. */
public final class Bvc2RenderersFactory extends DefaultRenderersFactory {
  public Bvc2RenderersFactory(Context context) {
    super(context);
  }

  @Override
  protected void buildVideoRenderers(
      Context context,
      int extensionRendererMode,
      MediaCodecSelector mediaCodecSelector,
      boolean enableDecoderFallback,
      Handler eventHandler,
      VideoRendererEventListener eventListener,
      long allowedVideoJoiningTimeMs,
      ArrayList<Renderer> out) {
    super.buildVideoRenderers(
        context,
        extensionRendererMode,
        mediaCodecSelector,
        enableDecoderFallback,
        eventHandler,
        eventListener,
        allowedVideoJoiningTimeMs,
        out);
    if (Bvc2Native.isAvailable()) {
      out.add(new Bvc2VideoRenderer(eventHandler, eventListener));
    }
  }
}
