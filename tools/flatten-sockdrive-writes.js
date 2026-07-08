// Flatten a sockdrive write-store blob (serializeSectors format) into a raw disk image.
// Format: u32le sectorCount, then per sector: u32le blockLen + block.
//   blockLen == 516  -> raw:  u32le absolute LBA + 512 bytes data
//   blockLen != 516  -> LZ4 block decoding to 516 bytes (u32le LBA + 512 data)
// LZ4 block decoder ported from js-dos mini-lz4 (node-lz4, MIT, (c) 2012 Pierre Curto).
const fs = require("fs");

function lz4Uncompress(input, output) {
  for (let i = 0, n = input.length, j = 0; i < n;) {
    const token = input[i++];
    let literals_length = (token >> 4);
    if (literals_length > 0) {
      let l = literals_length + 240;
      while (l === 255) { l = input[i++]; literals_length += l; }
      const end = i + literals_length;
      while (i < end) output[j++] = input[i++];
      if (i === n) return j;
    }
    const offset = input[i++] | (input[i++] << 8);
    if (offset === 0) return j;
    if (offset > j) return -(i - 2);
    let match_length = (token & 0xf);
    let l = match_length + 240;
    while (l === 255) { l = input[i++]; match_length += l; }
    let pos = j - offset;
    const end = j + match_length + 4;
    while (j < end) output[j++] = output[pos++];
  }
  return -1;
}

const [blobPath, imgPath] = process.argv.slice(2);
const blob = fs.readFileSync(blobPath);
const fd = fs.openSync(imgPath, "r+");
const imgSectors = fs.fstatSync(fd).size / 512;

const count = blob.readUInt32LE(0);
let offset = 4, applied = 0, minLba = Infinity, maxLba = -1, rawBlocks = 0, lz4Blocks = 0;
const out = Buffer.alloc(516);
for (let i = 0; i < count; i++) {
  const len = blob.readUInt32LE(offset); offset += 4;
  const block = blob.subarray(offset, offset + len); offset += len;
  let sector, data;
  if (len === 516) {
    sector = block.readUInt32LE(0); data = block.subarray(4); rawBlocks++;
  } else {
    const n = lz4Uncompress(block, out);
    if (n !== 516) { console.error(`decode fail at record ${i}: got ${n}`); process.exit(1); }
    sector = out.readUInt32LE(0); data = out.subarray(4); lz4Blocks++;
  }
  if (sector >= imgSectors) { console.error(`LBA ${sector} out of range at record ${i}`); process.exit(1); }
  fs.writeSync(fd, data, 0, 512, sector * 512);
  applied++;
  if (sector < minLba) minLba = sector;
  if (sector > maxLba) maxLba = sector;
}
fs.closeSync(fd);
console.log(JSON.stringify({ count, applied, rawBlocks, lz4Blocks, minLba, maxLba, blobBytes: blob.length, trailing: blob.length - offset }));
