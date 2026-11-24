package cn.freeplayer.app.bvc2;

import androidx.media3.common.ParserException;
import java.io.ByteArrayOutputStream;

/**
 * Parses the private bv2C configuration record into the Annex-B parameter-set
 * prefix the vendor decoder expects, and reports the NAL length-field size.
 */
public final class Bvc2Config {
  public final int nalLengthSize;
  public final byte[] annexB;

  private Bvc2Config(int nalLengthSize, byte[] annexB) {
    this.nalLengthSize = nalLengthSize;
    this.annexB = annexB;
  }

  public static Bvc2Config parse(byte[] bytes) throws ParserException {
    try {
      Cursor cursor = new Cursor(bytes);
      if (cursor.u8() != 1) throw new IllegalArgumentException("unsupported bv2C version");
      int flags = cursor.u8();
      int lengthSize = ((flags >> 1) & 7) + 1;
      if (lengthSize > 4) throw new IllegalArgumentException("invalid NAL length size");
      if ((flags & 1) != 0) {
        cursor.skip(2);
        int sublayers = cursor.u8() - 1;
        cursor.skip(3);
        if (sublayers < 0 || sublayers > 7) {
          throw new IllegalArgumentException("invalid sublayers");
        }
        cursor.skip(sublayers);
        int present = cursor.u8();
        for (int mask = 128; mask != 0; mask >>= 1) {
          if ((present & mask) != 0) cursor.skip(1);
        }
        cursor.skip(cursor.u8() * 4);
        cursor.skip(8);
      }
      int arrays = cursor.u8();
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      for (int i = 0; i < arrays; i++) {
        cursor.skip(1);
        int count = cursor.u16();
        for (int j = 0; j < count; j++) {
          int length = cursor.u16();
          if (length == 0) throw new IllegalArgumentException("empty parameter NAL");
          cursor.require(length);
          out.write(0);
          out.write(0);
          out.write(0);
          out.write(1);
          out.write(bytes, cursor.at, length);
          cursor.skip(length);
        }
      }
      if (cursor.at != bytes.length) {
        throw new IllegalArgumentException("trailing bv2C data");
      }
      return new Bvc2Config(lengthSize, out.toByteArray());
    } catch (IllegalArgumentException error) {
      throw ParserException.createForMalformedContainer(
          "Invalid BVC2 configuration", error);
    }
  }

  private static final class Cursor {
    final byte[] bytes;
    int at;

    Cursor(byte[] bytes) {
      this.bytes = bytes;
    }

    void require(int count) {
      if (count < 0 || count > bytes.length - at) {
        throw new IllegalArgumentException("truncated bv2C");
      }
    }

    void skip(int count) {
      require(count);
      at += count;
    }

    int u8() {
      require(1);
      return bytes[at++] & 255;
    }

    int u16() {
      return (u8() << 8) | u8();
    }
  }
}
