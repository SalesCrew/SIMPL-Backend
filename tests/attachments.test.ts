import { describe, it, expect } from "vitest";
import {
  fileTypes,
  MAX_FILE_SIZE,
  MAX_PREVIEW_SIZE,
  validateFile,
  validFileBytes,
} from "../src/attachment-validation.js";
describe("attachment validation", () => {
  it("accepts supported types including empty browser MIME types", () => {
    for (const [ext, mime] of Object.entries(fileTypes))
      expect(validateFile("Screenshot." + ext.toUpperCase(), 200)).toBe(mime);
  });
  it.each(["../file.png", "file\\image.png", "x\u202egnp.exe", "file.png\n"])(
    "rejects unsafe or unsupported name %s",
    (name) => {
      expect(() => validateFile(name, 100)).toThrow();
    },
  );
  it.each([
    "file.svg",
    "file.html",
    "file.exe",
    "file.js",
    "file.docm",
    "file.doc",
    "file.xls",
    "file.7z",
    "file",
  ])("serves unfamiliar format %s as an opaque download", (name) => {
    expect(validateFile(name, 100)).toBe("application/octet-stream");
    expect(
      validFileBytes(new Uint8Array([0, 255, 8]), "application/octet-stream"),
    ).toBe(true);
  });
  it.each([0, -1, 1.5, NaN, Infinity, MAX_FILE_SIZE + 1])(
    "rejects invalid size %s",
    (size) => {
      expect(() => validateFile("file.png", size)).toThrow();
    },
  );
  it("accepts the exact limit and blocks long filenames", () => {
    expect(MAX_FILE_SIZE).toBe(500 * 1024 * 1024);
    expect(validateFile("file.zip", MAX_FILE_SIZE)).toBe(
      "application/octet-stream",
    );
    expect(validateFile("image.png", MAX_PREVIEW_SIZE)).toBe(fileTypes.png);
    expect(validateFile("image.png", MAX_PREVIEW_SIZE + 1)).toBe(
      "application/octet-stream",
    );
    expect(() => validateFile("a".repeat(180) + ".png", 1)).toThrow();
  });
  it("rejects forged image content and unknown formats", () => {
    const text = new TextEncoder().encode("<html>not a screenshot</html>");
    for (const mime of [
      "image/png",
      "image/jpeg",
      "image/webp",
      "image/gif",
      "application/pdf",
      "application/zip",
      "text/html",
    ])
      expect(validFileBytes(text, mime)).toBe(false);
  });
  it("checks UTF-8 and binary controls in text", () => {
    expect(
      validFileBytes(new TextEncoder().encode("Grüße, Team!"), "text/plain"),
    ).toBe(true);
    expect(validFileBytes(Uint8Array.from([0, 65]), "text/plain")).toBe(false);
    expect(validFileBytes(Uint8Array.from([255, 254, 65]), "text/plain")).toBe(
      false,
    );
  });
});
