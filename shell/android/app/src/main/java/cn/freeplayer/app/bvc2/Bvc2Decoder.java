package cn.freeplayer.app.bvc2;

import androidx.media3.common.C;
import androidx.media3.decoder.Decoder;
import androidx.media3.decoder.DecoderException;
import androidx.media3.decoder.DecoderInputBuffer;
import androidx.media3.decoder.VideoDecoderOutputBuffer;
import java.util.ArrayDeque;

/**
 * Runs the vendor decoder on its own thread. Media3 owns the audio clock, so
 * decoded VVC frames are queued and released on demand instead of being
 * rendered inline while the packet is decoded.
 */
final class Bvc2Decoder
    implements Decoder<DecoderInputBuffer, VideoDecoderOutputBuffer, DecoderException> {
  private final Object lock = new Object();
  private final ArrayDeque<DecoderInputBuffer> freeInputs = new ArrayDeque<>();
  private final ArrayDeque<DecoderInputBuffer> pendingInputs = new ArrayDeque<>();
  private final ArrayDeque<VideoDecoderOutputBuffer> freeOutputs = new ArrayDeque<>();
  private final ArrayDeque<VideoDecoderOutputBuffer> readyOutputs = new ArrayDeque<>();
  private final byte[] config;
  private final Thread worker;
  private DecoderException failure;
  private DecoderInputBuffer dequeued;
  private boolean released;
  private int generation;
  private long outputStartTimeUs = C.TIME_UNSET;

  Bvc2Decoder(byte[] config) {
    this.config = config.clone();
    for (int i = 0; i < 4; i++) {
      freeInputs.add(
          new DecoderInputBuffer(DecoderInputBuffer.BUFFER_REPLACEMENT_MODE_DIRECT));
    }
    for (int i = 0; i < 8; i++) {
      freeOutputs.add(new VideoDecoderOutputBuffer(this::releaseOutput));
    }
    worker = new Thread(this::run, "FreePlayer:BVC2");
    worker.start();
  }

  @Override
  public String getName() {
    return "FreePlayer BVC2";
  }

  private void checkFailure() throws DecoderException {
    if (failure != null) throw failure;
  }

  @Override
  public DecoderInputBuffer dequeueInputBuffer() throws DecoderException {
    synchronized (lock) {
      checkFailure();
      if (released || dequeued != null || freeInputs.isEmpty()) return null;
      dequeued = freeInputs.removeFirst();
      return dequeued;
    }
  }

  @Override
  public void queueInputBuffer(DecoderInputBuffer input) throws DecoderException {
    synchronized (lock) {
      checkFailure();
      if (input != dequeued || released) {
        throw new IllegalStateException("Invalid BVC2 input ownership");
      }
      pendingInputs.addLast(input);
      dequeued = null;
      lock.notifyAll();
    }
  }

  @Override
  public VideoDecoderOutputBuffer dequeueOutputBuffer() throws DecoderException {
    synchronized (lock) {
      checkFailure();
      return readyOutputs.pollFirst();
    }
  }

  private void releaseOutput(VideoDecoderOutputBuffer output) {
    synchronized (lock) {
      output.clear();
      freeOutputs.addLast(output);
      lock.notifyAll();
    }
  }

  @Override
  public void setOutputStartTimeUs(long timeUs) {
    synchronized (lock) {
      outputStartTimeUs = timeUs;
    }
  }

  @Override
  public void flush() {
    synchronized (lock) {
      generation++;
      outputStartTimeUs = C.TIME_UNSET;
      if (dequeued != null) {
        dequeued.clear();
        freeInputs.addLast(dequeued);
        dequeued = null;
      }
      while (!pendingInputs.isEmpty()) {
        DecoderInputBuffer input = pendingInputs.removeFirst();
        input.clear();
        freeInputs.addLast(input);
      }
      while (!readyOutputs.isEmpty()) releaseOutput(readyOutputs.removeFirst());
      lock.notifyAll();
    }
  }

  @Override
  public void release() {
    synchronized (lock) {
      released = true;
      lock.notifyAll();
    }
    boolean interrupted = false;
    for (;;) {
      try {
        worker.join();
        break;
      } catch (InterruptedException error) {
        interrupted = true;
      }
    }
    if (interrupted) Thread.currentThread().interrupt();
  }

  private void run() {
    long handle = 0;
    int handleGeneration = -1;
    DecoderInputBuffer input = null;
    int jobGeneration = -1;
    int drainCount = 0;
    try {
      for (;;) {
        VideoDecoderOutputBuffer output;
        synchronized (lock) {
          if (input != null && jobGeneration != generation) {
            input.clear();
            freeInputs.addLast(input);
            input = null;
          }
          while (!released &&
              (freeOutputs.isEmpty() || (input == null && pendingInputs.isEmpty()))) {
            lock.wait();
          }
          if (released) break;
          if (input == null) {
            input = pendingInputs.removeFirst();
            jobGeneration = generation;
            drainCount = 0;
          }
          output = freeOutputs.removeFirst();
        }
        if (handleGeneration != jobGeneration) {
          if (handle != 0) Bvc2Native.destroy(handle);
          handle = Bvc2Native.create(config);
          handleGeneration = jobGeneration;
        }
        boolean end = input.isEndOfStream();
        java.nio.ByteBuffer data = end ? null : input.data;
        output.init(input.timeUs, C.VIDEO_OUTPUT_MODE_SURFACE_YUV, null);
        boolean gotFrame =
            Bvc2Native.decode(
                handle,
                data,
                data == null ? 0 : data.position(),
                data == null ? 0 : data.remaining(),
                input.timeUs,
                output);
        if (end && !gotFrame) output.addFlag(C.BUFFER_FLAG_END_OF_STREAM);
        if (end && ++drainCount > 64) {
          throw new IllegalStateException("BVC2 drain did not finish");
        }
        synchronized (lock) {
          if (jobGeneration == generation && (gotFrame || end)) {
            output.shouldBeSkipped =
                gotFrame && outputStartTimeUs != C.TIME_UNSET &&
                    output.timeUs < outputStartTimeUs;
            readyOutputs.addLast(output);
          } else {
            releaseOutput(output);
          }
          if (!end || !gotFrame) {
            input.clear();
            freeInputs.addLast(input);
            input = null;
          }
        }
      }
    } catch (Exception | LinkageError error) {
      synchronized (lock) {
        failure = new DecoderException("BVC2 decode failed", error);
        lock.notifyAll();
      }
    } finally {
      if (handle != 0) Bvc2Native.destroy(handle);
    }
  }
}
