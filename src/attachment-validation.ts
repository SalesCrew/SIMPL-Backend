export const MAX_FILE_SIZE = 500 * 1024 * 1024;
export const MAX_PREVIEW_SIZE = 20 * 1024 * 1024;
export const fileTypes: Record<string, string> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  webp: "image/webp",
  gif: "image/gif",
  pdf: "application/pdf",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  txt: "text/plain",
  csv: "text/csv",
  md: "text/markdown",
  zip: "application/zip",
};
export function validateFile(filename: string, size: number) {
  const extension = filename.split(".").at(-1)?.toLowerCase() || "";
  if (
    !filename.trim() ||
    filename.length > 180 ||
    /[\x00-\x1f\x7f/\\\u202a-\u202e\u2066-\u2069]/.test(filename)
  )
    throw new Error(
      "Bitte einen einfachen Dateinamen mit höchstens 180 Zeichen verwenden.",
    );
  if (!Number.isSafeInteger(size) || size < 1 || size > MAX_FILE_SIZE)
    throw new Error("Eine Datei muss zwischen 1 Byte und 500 MB groß sein.");
  if (size > MAX_PREVIEW_SIZE) return "application/octet-stream";
  return Object.hasOwn(fileTypes, extension)
    ? fileTypes[extension]
    : "application/octet-stream";
}
export function validFileBytes(bytes: Uint8Array, mime: string): boolean {
  const starts = (...values: number[]) =>
    values.every((v, i) => bytes[i] === v);
  const ascii = (start: number, end: number) =>
    String.fromCharCode(...bytes.slice(start, end));
  switch (mime) {
    // Unrecognized formats are opaque downloads, not executable previews.
    case "application/octet-stream":
      return bytes.length > 0;
    case "image/png":
      return (
        bytes.length >= 24 &&
        starts(137, 80, 78, 71, 13, 10, 26, 10) &&
        ascii(12, 16) === "IHDR"
      );
    case "image/jpeg":
      return (
        bytes.length >= 4 &&
        starts(255, 216, 255) &&
        bytes.at(-2) === 255 &&
        bytes.at(-1) === 217
      );
    case "image/gif":
      return bytes.length >= 14 && ["GIF87a", "GIF89a"].includes(ascii(0, 6));
    case "image/webp":
      return (
        bytes.length >= 20 && ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP"
      );
    case "application/pdf":
      return ascii(0, 5) === "%PDF-";
    case "application/zip":
    case fileTypes.docx:
    case fileTypes.xlsx:
    case fileTypes.pptx:
      return starts(80, 75, 3, 4) || starts(80, 75, 5, 6);
    case "text/plain":
    case "text/csv":
    case "text/markdown":
      try {
        new TextDecoder("utf-8", { fatal: true }).decode(bytes);
        return !bytes.includes(0);
      } catch {
        return false;
      }
    default:
      return false;
  }
}
