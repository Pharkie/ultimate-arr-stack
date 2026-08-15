import zlib from 'zlib';
import { logger } from './logger.js';

export function extractSrtFromZip(buffer) {
  const entries = readCentralDirectory(buffer) ?? readLocalHeaders(buffer);
  if (!entries?.length) return null;

  const srtEntries = entries
    .filter(entry => /\.srt$/i.test(entry.filename))
    .sort((a, b) => b.uncompressedSize - a.uncompressedSize);

  for (const entry of srtEntries) {
    const data = readEntryData(buffer, entry);
    if (!data) continue;
    return decodeSubtitleText(data);
  }

  return null;
}

export function decodeSubtitleText(buffer) {
  const utf8 = buffer.toString('utf8');
  if (!utf8.includes('�')) return stripBom(utf8);

  try {
    return stripBom(buffer.toString('latin1'));
  } catch {
    return stripBom(utf8);
  }
}

function readCentralDirectory(buffer) {
  const eocdOffset = findEocdOffset(buffer);
  if (eocdOffset < 0) return null;

  const entryCount = buffer.readUInt16LE(eocdOffset + 10);
  const cdSize = buffer.readUInt32LE(eocdOffset + 12);
  const cdOffset = buffer.readUInt32LE(eocdOffset + 16);

  if (cdOffset + cdSize > buffer.length) return null;

  const entries = [];
  let offset = cdOffset;
  for (let i = 0; i < entryCount; i++) {
    if (offset + 46 > buffer.length) return null;
    if (buffer.readUInt32LE(offset) !== 0x02014b50) return null;

    const method = buffer.readUInt16LE(offset + 10);
    const compressedSize = buffer.readUInt32LE(offset + 20);
    const uncompressedSize = buffer.readUInt32LE(offset + 24);
    const filenameLen = buffer.readUInt16LE(offset + 28);
    const extraLen = buffer.readUInt16LE(offset + 30);
    const commentLen = buffer.readUInt16LE(offset + 32);
    const localHeaderOffset = buffer.readUInt32LE(offset + 42);

    const filename = buffer
      .slice(offset + 46, offset + 46 + filenameLen)
      .toString('utf8');

    entries.push({
      filename,
      method,
      compressedSize,
      uncompressedSize,
      localHeaderOffset,
    });

    offset += 46 + filenameLen + extraLen + commentLen;
  }

  return entries;
}

function findEocdOffset(buffer) {
  const minOffset = Math.max(0, buffer.length - 65557);
  for (let i = buffer.length - 22; i >= minOffset; i--) {
    if (buffer.readUInt32LE(i) === 0x06054b50) return i;
  }
  return -1;
}

function readLocalHeaders(buffer) {
  const entries = [];
  let offset = 0;
  while (offset + 30 <= buffer.length) {
    if (buffer.readUInt32LE(offset) !== 0x04034b50) break;

    const method = buffer.readUInt16LE(offset + 8);
    const compressedSize = buffer.readUInt32LE(offset + 18);
    const uncompressedSize = buffer.readUInt32LE(offset + 22);
    const filenameLen = buffer.readUInt16LE(offset + 26);
    const extraLen = buffer.readUInt16LE(offset + 28);

    const filename = buffer
      .slice(offset + 30, offset + 30 + filenameLen)
      .toString('utf8');

    const dataStart = offset + 30 + filenameLen + extraLen;
    if (!compressedSize) return entries.length ? entries : null;

    entries.push({
      filename,
      method,
      compressedSize,
      uncompressedSize,
      localHeaderOffset: offset,
      dataStart,
    });

    offset = dataStart + compressedSize;
  }
  return entries;
}

function readEntryData(buffer, entry) {
  let dataStart = entry.dataStart;

  if (dataStart == null) {
    const headerOffset = entry.localHeaderOffset;
    if (headerOffset + 30 > buffer.length) return null;
    if (buffer.readUInt32LE(headerOffset) !== 0x04034b50) return null;

    const filenameLen = buffer.readUInt16LE(headerOffset + 26);
    const extraLen = buffer.readUInt16LE(headerOffset + 28);
    dataStart = headerOffset + 30 + filenameLen + extraLen;
  }

  const dataEnd = dataStart + entry.compressedSize;
  if (dataEnd > buffer.length) return null;
  const compressed = buffer.slice(dataStart, dataEnd);

  try {
    if (entry.method === 0) return compressed;
    if (entry.method === 8) return zlib.inflateRawSync(compressed);
  } catch (err) {
    logger.warn(`Zip inflate failed: ${err.message}`);
  }
  return null;
}

function stripBom(text) {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}
