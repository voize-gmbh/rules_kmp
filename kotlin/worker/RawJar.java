package de.voize.bazel.kotlin;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.zip.CRC32;
import java.util.zip.DataFormatException;
import java.util.zip.Inflater;

/**
 * Reads and writes jars without inflating the entries that are only copied, so a filtered copy of a
 * large jar costs little more than the bytes it moves, and those bytes are the input's.
 *
 * <p>Only plain zips are read: no Zip64 and no encryption. {@link #read} throws {@link
 * UnsupportedJarException} for anything else, and callers fall back to java.util.zip.
 */
final class RawJar {
  private static final int LOCAL = 0x04034b50;
  private static final int CENTRAL = 0x02014b50;
  private static final int END = 0x06054b50;
  private static final int UTF8_NAMES = 0x0800;
  // 2010-01-01 00:00 in MS-DOS format, as KotlinBuilder's jars.
  private static final int DOS_DATE = ((2010 - 1980) << 9) | (1 << 5) | 1;
  private static final int DOS_TIME = 0;

  /** One entry: its name and its data as stored in the jar (deflated or not). */
  record Entry(String name, int method, long crc, long size, byte[] raw) {
    byte[] data() throws IOException {
      if (method == 0) {
        return raw;
      }
      Inflater inflater = new Inflater(true);
      try {
        inflater.setInput(raw);
        byte[] out = new byte[Math.toIntExact(size)];
        int n = 0;
        while (n < out.length) {
          int r = inflater.inflate(out, n, out.length - n);
          if (r == 0 && (inflater.finished() || inflater.needsInput())) {
            break;
          }
          n += r;
        }
        if (n != out.length) {
          throw new IOException("Truncated entry " + name);
        }
        return out;
      } catch (DataFormatException e) {
        throw new IOException("Corrupt entry " + name, e);
      } finally {
        inflater.end();
      }
    }

    static Entry stored(String name, byte[] data) {
      CRC32 crc = new CRC32();
      crc.update(data);
      return new Entry(name, 0, crc.getValue(), data.length, data);
    }
  }

  static final class UnsupportedJarException extends IOException {
    private static final long serialVersionUID = 1L;

    UnsupportedJarException(String message) {
      super(message);
    }
  }

  static List<Entry> read(Path jar) throws IOException {
    byte[] bytes = Files.readAllBytes(jar);
    ByteBuffer b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
    int end = -1;
    for (int i = bytes.length - 22; i >= Math.max(0, bytes.length - 22 - 0xffff); i--) {
      if (b.getInt(i) == END) {
        end = i;
        break;
      }
    }
    if (end < 0) {
      throw new UnsupportedJarException("No end of central directory in " + jar);
    }
    int count = Short.toUnsignedInt(b.getShort(end + 10));
    long offset = Integer.toUnsignedLong(b.getInt(end + 16));
    if (count == 0xffff || offset == 0xffffffffL) {
      throw new UnsupportedJarException("Zip64 jar " + jar);
    }
    List<Entry> entries = new ArrayList<>(count);
    int p = Math.toIntExact(offset);
    for (int i = 0; i < count; i++) {
      if (b.getInt(p) != CENTRAL) {
        throw new UnsupportedJarException("Bad central directory in " + jar);
      }
      int flags = Short.toUnsignedInt(b.getShort(p + 8));
      int method = Short.toUnsignedInt(b.getShort(p + 10));
      long crc = Integer.toUnsignedLong(b.getInt(p + 16));
      long compressed = Integer.toUnsignedLong(b.getInt(p + 20));
      long size = Integer.toUnsignedLong(b.getInt(p + 24));
      int nameLength = Short.toUnsignedInt(b.getShort(p + 28));
      int extraLength = Short.toUnsignedInt(b.getShort(p + 30));
      int commentLength = Short.toUnsignedInt(b.getShort(p + 32));
      long local = Integer.toUnsignedLong(b.getInt(p + 42));
      if ((flags & 1) != 0 || (method != 0 && method != 8)
          || compressed == 0xffffffffL || size == 0xffffffffL || local == 0xffffffffL) {
        throw new UnsupportedJarException("Unsupported entry in " + jar);
      }
      String name = new String(bytes, p + 46, nameLength, StandardCharsets.UTF_8);
      int l = Math.toIntExact(local);
      if (b.getInt(l) != LOCAL) {
        throw new UnsupportedJarException("Bad local header in " + jar);
      }
      int data = l + 30 + Short.toUnsignedInt(b.getShort(l + 26)) + Short.toUnsignedInt(b.getShort(l + 28));
      byte[] raw = new byte[Math.toIntExact(compressed)];
      System.arraycopy(bytes, data, raw, 0, raw.length);
      entries.add(new Entry(name, method, crc, size, raw));
      p += 46 + nameLength + extraLength + commentLength;
    }
    return entries;
  }

  /** Writes {@code entries} in order, with fixed times and no extra fields. */
  static void write(Path jar, List<Entry> entries) throws IOException {
    if (entries.size() >= 0xffff) {
      throw new UnsupportedJarException("Too many entries for a plain zip: " + entries.size());
    }
    ByteArrayOutputStream central = new ByteArrayOutputStream();
    Files.createDirectories(jar.toAbsolutePath().getParent());
    try (OutputStream out = new java.io.BufferedOutputStream(Files.newOutputStream(jar), 1 << 16)) {
      long offset = 0;
      for (Entry e : entries) {
        byte[] name = e.name().getBytes(StandardCharsets.UTF_8);
        if (offset > 0xfffffffeL) {
          throw new UnsupportedJarException("Jar too large for a plain zip");
        }
        ByteBuffer local = header(30 + name.length);
        local.putInt(LOCAL).putShort((short) 20).putShort((short) UTF8_NAMES).putShort((short) e.method())
            .putShort((short) DOS_TIME).putShort((short) DOS_DATE).putInt((int) e.crc())
            .putInt(e.raw().length).putInt((int) e.size()).putShort((short) name.length).putShort((short) 0)
            .put(name);
        out.write(local.array());
        out.write(e.raw());
        ByteBuffer c = header(46 + name.length);
        c.putInt(CENTRAL).putShort((short) 20).putShort((short) 20).putShort((short) UTF8_NAMES)
            .putShort((short) e.method()).putShort((short) DOS_TIME).putShort((short) DOS_DATE)
            .putInt((int) e.crc()).putInt(e.raw().length).putInt((int) e.size())
            .putShort((short) name.length).putShort((short) 0).putShort((short) 0).putShort((short) 0)
            .putShort((short) 0).putInt(0).putInt((int) offset).put(name);
        central.write(c.array());
        offset += 30 + name.length + e.raw().length;
      }
      if (offset > 0xfffffffeL) {
        throw new UnsupportedJarException("Jar too large for a plain zip");
      }
      central.writeTo(out);
      ByteBuffer end = header(22);
      end.putInt(END).putShort((short) 0).putShort((short) 0).putShort((short) entries.size())
          .putShort((short) entries.size()).putInt(central.size()).putInt((int) offset).putShort((short) 0);
      out.write(end.array());
    }
  }

  private static ByteBuffer header(int size) {
    return ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN);
  }
}
