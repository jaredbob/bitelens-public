// Check JPEG framing, segment lengths, and dimensions before forwarding.
// The provider decodes the compressed scan. The iPhone re-encodes captures.
export function isJPEG(bytes: string): boolean {
  if (!bytes.startsWith("\xff\xd8") || !bytes.endsWith("\xff\xd9")) return false;
  const wordAt = (index: number) => bytes.charCodeAt(index) * 256 + bytes.charCodeAt(index + 1);
  let foundFrame = false;
  let index = 2;
  while (index + 4 < bytes.length) {
    if (bytes.charCodeAt(index++) !== 0xff) return false;
    while (bytes.charCodeAt(index) === 0xff) index++;
    const marker = bytes.charCodeAt(index++);
    const length = wordAt(index);
    if (!(length >= 2 && index + length < bytes.length - 2)) return false;
    if ([0xc0, 0xc1, 0xc2].includes(marker)) {
      if (length < 8) return false;
      const height = wordAt(index + 3);
      const width = wordAt(index + 5);
      if (width < 1 || width > 1_600 || height < 1 || height > 1_600) return false;
      foundFrame = true;
    }
    if (marker === 0xda) return foundFrame && length >= 6;
    index += length;
  }
  return false;
}
