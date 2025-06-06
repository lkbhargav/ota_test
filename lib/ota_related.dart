import 'dart:typed_data';

const chunkSize = 200;
const int crc32Polynomial = 0xEDB88320;
const int crc32Seed = 0xFFFFFFFF;

enum ChunkStatus { ok, end, error }

class OtaRelated {
  final ByteData _fileContent;
  int _index = -1;
  Uint8List? _currentChunk;

  OtaRelated(this._fileContent);

  (ByteData?, ChunkStatus) getCurrentChunk() {
    if (_fileContent.lengthInBytes == 0 ||
        _index * chunkSize >= _fileContent.lengthInBytes) {
      _index -= 1;
      return (null, ChunkStatus.end);
    }

    int remaining = _fileContent.lengthInBytes - (_index * chunkSize);
    int size = remaining < chunkSize ? remaining : chunkSize;

    final chunkBytes = _fileContent.buffer.asUint8List(
      _fileContent.offsetInBytes + (_index * chunkSize),
      size,
    );

    _currentChunk = chunkBytes;

    var (checksum, crcValue) = crc32();

    if (checksum == null) {
      _index -= 1;
      return (null, ChunkStatus.error);
    }

    print("Checksum: String: $checksum | Int: $crcValue");

    // Create new Uint8List with 2 bytes for index, 2 bytes for chunk length, plus the actual chunk
    final resultBytes = Uint8List(8 + size);
    final byteData = ByteData.sublistView(resultBytes);

    byteData.setUint16(0, _index, Endian.big); // 2 bytes for index
    byteData.setUint16(2, size, Endian.big); // 2 bytes for chunk length
    byteData.setUint32(4, crcValue, Endian.big);
    resultBytes.setRange(8, 8 + size, chunkBytes); // actual chunk data

    return (byteData, ChunkStatus.ok);
  }

  (ByteData?, ChunkStatus) getNextChunk() {
    _index += 1;

    return getCurrentChunk();
  }

  int getIndex() {
    return _index;
  }

  (String?, int) crc32() {
    if (_currentChunk == null) {
      return (null, 0);
    }

    int crc = crc32Seed;

    for (var b in _currentChunk!) {
      crc ^= b;
      for (int i = 0; i < 8; i++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ crc32Polynomial;
        } else {
          crc >>= 1;
        }
      }
    }

    crc ^= crc32Seed;

    // Format as 8-character hex string, padded with leading zeros if necessary
    return (crc.toRadixString(16).padLeft(8, '0'), crc);
  }
}
