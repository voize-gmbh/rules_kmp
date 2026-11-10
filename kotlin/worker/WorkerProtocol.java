package de.voize.bazel.kotlin;

import java.io.BufferedInputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

/**
 * Bazel's default worker protocol (worker_protocol.proto): length-delimited WorkRequest and
 * WorkResponse messages. Remote executors such as BuildBuddy only learn the protocol from Bazel's
 * default, so the workers speak it rather than the JSON variant.
 */
final class WorkerProtocol {
  record Request(List<String> arguments, int requestId) {}

  private static final int ARGUMENTS = 1;
  private static final int REQUEST_ID = 3;
  private static final int EXIT_CODE = 1;
  private static final int OUTPUT = 2;
  private static final int RESPONSE_REQUEST_ID = 3;
  private static final int VARINT = 0;
  private static final int FIXED64 = 1;
  private static final int LENGTH_DELIMITED = 2;
  private static final int FIXED32 = 5;

  /** Runs one request: its arguments, with flag files expanded, and where to write diagnostics. */
  interface Handler {
    int handle(List<String> args, PrintStream out) throws Exception;
  }

  /** Answers requests from stdin until it closes. */
  static void serve(Handler handler) throws IOException {
    PrintStream realOut = System.out;
    // Compilers occasionally print to stdout; keep it off the protocol stream.
    System.setOut(System.err);
    InputStream in = new BufferedInputStream(System.in);
    Request request;
    while ((request = read(in)) != null) {
      ByteArrayOutputStream buf = new ByteArrayOutputStream();
      int code;
      boolean fatal = false;
      try (PrintStream ps = new PrintStream(buf, true, StandardCharsets.UTF_8)) {
        try {
          code = handler.handle(expandFlagFiles(request.arguments()), ps);
        } catch (Error e) {
          e.printStackTrace(ps);
          code = 1;
          fatal = true;
        } catch (Throwable t) {
          t.printStackTrace(ps);
          code = 1;
        }
      }
      write(realOut, code, buf.toString(StandardCharsets.UTF_8), request.requestId());
      // Compilers keep state in this JVM between requests; after an Error it can't be trusted.
      if (fatal) {
        System.exit(1);
      }
    }
  }

  static List<String> expandFlagFiles(List<String> args) throws IOException {
    List<String> result = new ArrayList<>();
    for (String a : args) {
      if (a.startsWith("@") && !a.startsWith("@@")) {
        for (String l : Files.readAllLines(Paths.get(a.substring(1)), StandardCharsets.UTF_8)) {
          if (!l.isEmpty()) {
            result.add(l);
          }
        }
      } else {
        result.add(a);
      }
    }
    return result;
  }

  /** The next request, or null at the end of the stream. Fields the workers don't use are skipped. */
  static Request read(InputStream in) throws IOException {
    Long size = varintOrEnd(in);
    if (size == null) {
      return null;
    }
    InputStream message = new ByteArrayInputStream(exactly(in, size));
    List<String> arguments = new ArrayList<>();
    int requestId = 0;
    Long tag;
    while ((tag = varintOrEnd(message)) != null) {
      int field = (int) (tag >>> 3);
      int wireType = (int) (tag & 7);
      if (field == ARGUMENTS && wireType == LENGTH_DELIMITED) {
        arguments.add(new String(exactly(message, varint(message)), StandardCharsets.UTF_8));
      } else if (field == REQUEST_ID && wireType == VARINT) {
        requestId = (int) varint(message);
      } else {
        skip(message, wireType);
      }
    }
    return new Request(arguments, requestId);
  }

  static void write(OutputStream out, int exitCode, String output, int requestId) throws IOException {
    ByteArrayOutputStream message = new ByteArrayOutputStream();
    writeVarint(message, EXIT_CODE << 3 | VARINT);
    writeVarint(message, exitCode);
    byte[] text = output.getBytes(StandardCharsets.UTF_8);
    writeVarint(message, OUTPUT << 3 | LENGTH_DELIMITED);
    writeVarint(message, text.length);
    message.write(text);
    writeVarint(message, RESPONSE_REQUEST_ID << 3 | VARINT);
    writeVarint(message, requestId);
    writeVarint(out, message.size());
    message.writeTo(out);
    out.flush();
  }

  private static Long varintOrEnd(InputStream in) throws IOException {
    int first = in.read();
    return first < 0 ? null : varint(in, first);
  }

  private static long varint(InputStream in) throws IOException {
    return varint(in, in.read());
  }

  private static long varint(InputStream in, int b) throws IOException {
    long value = 0;
    for (int shift = 0; shift < 64; shift += 7) {
      if (b < 0) {
        throw new EOFException("truncated work request");
      }
      value |= (long) (b & 0x7f) << shift;
      if ((b & 0x80) == 0) {
        return value;
      }
      b = in.read();
    }
    throw new IOException("malformed varint in work request");
  }

  private static byte[] exactly(InputStream in, long size) throws IOException {
    byte[] bytes = in.readNBytes(Math.toIntExact(size));
    if (bytes.length != size) {
      throw new EOFException("truncated work request");
    }
    return bytes;
  }

  private static void skip(InputStream in, int wireType) throws IOException {
    switch (wireType) {
      case VARINT -> varint(in);
      case FIXED64 -> exactly(in, 8);
      case LENGTH_DELIMITED -> exactly(in, varint(in));
      case FIXED32 -> exactly(in, 4);
      default -> throw new IOException("unsupported wire type " + wireType + " in work request");
    }
  }

  private static void writeVarint(OutputStream out, long value) throws IOException {
    while ((value & ~0x7fL) != 0) {
      out.write((int) ((value & 0x7f) | 0x80));
      value >>>= 7;
    }
    out.write((int) value);
  }
}
