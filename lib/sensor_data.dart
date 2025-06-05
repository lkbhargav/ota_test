import 'dart:typed_data';

class SensorDataBuffer {
  // Store last 60 seconds of data (60 readings per second)
  static const int maxReadings = 60;

  // Lists to store sensor readings with timestamps
  final List<SensorReading> _readings = [];

  void processSensorData(ByteData dataReceived) {
    // Validate buffer size
    if (dataReceived.lengthInBytes < 200) {
      print('Warning: Expected 200 bytes, got ${dataReceived.lengthInBytes}');
      return;
    }

    final timestamp = DateTime.now();
    final newReadings = <SensorReading>[];

    // Parse all 10 readings from the buffer
    for (int i = 0; i < 10; i++) {
      final offset = i * 20;

      final uProx1L = dataReceived.getUint16(offset, Endian.little);
      final uProx2L = dataReceived.getUint16(offset + 2, Endian.little);
      final uProx1R = dataReceived.getUint16(offset + 4, Endian.little);
      final uProx2R = dataReceived.getUint16(offset + 6, Endian.little);
      final uIR_HB = dataReceived.getUint16(offset + 8, Endian.little);
      final uIR_LB = dataReceived.getUint16(offset + 10, Endian.little);

      // Combine IR high and low bytes into 32-bit value
      final uIR = (uIR_HB << 16) | uIR_LB;

      newReadings.add(
        SensorReading(
          timestamp: timestamp,
          readingIndex: i,
          prox1L: uProx1L,
          prox2L: uProx2L,
          prox1R: uProx1R,
          prox2R: uProx2R,
          ir: uIR,
        ),
      );
    }

    // Add new readings
    _readings.addAll(newReadings);

    // Remove readings older than 1 minute
    _cleanupOldReadings();
  }

  void _cleanupOldReadings() {
    final cutoffTime = DateTime.now().subtract(const Duration(minutes: 1));
    _readings.removeWhere((reading) => reading.timestamp.isBefore(cutoffTime));

    // Also limit by count as backup (60 seconds * 10 readings = 600 max)
    while (_readings.length > maxReadings * 10) {
      _readings.removeAt(0);
    }
  }

  // Getter methods for accessing recent data
  List<SensorReading> get allReadings => List.unmodifiable(_readings);

  List<SensorReading> getReadingsInLastSeconds(int seconds) {
    final cutoffTime = DateTime.now().subtract(Duration(seconds: seconds));
    return _readings.where((r) => r.timestamp.isAfter(cutoffTime)).toList();
  }

  SensorReading? get latestReading => _readings.isEmpty ? null : _readings.last;

  // Get average values over last N seconds
  SensorAverages getAverages(int seconds) {
    final recentReadings = getReadingsInLastSeconds(seconds);
    if (recentReadings.isEmpty) return SensorAverages.zero();

    final count = recentReadings.length;
    return SensorAverages(
      prox1L:
          recentReadings.map((r) => r.prox1L).reduce((a, b) => a + b) / count,
      prox2L:
          recentReadings.map((r) => r.prox2L).reduce((a, b) => a + b) / count,
      prox1R:
          recentReadings.map((r) => r.prox1R).reduce((a, b) => a + b) / count,
      prox2R:
          recentReadings.map((r) => r.prox2R).reduce((a, b) => a + b) / count,
      ir: recentReadings.map((r) => r.ir).reduce((a, b) => a + b) / count,
    );
  }

  int get readingCount => _readings.length;

  void clear() => _readings.clear();
}

class SensorReading {
  final DateTime timestamp;
  final int readingIndex; // 0-9 for the 10 readings per packet
  final int prox1L;
  final int prox2L;
  final int prox1R;
  final int prox2R;
  final int ir;

  const SensorReading({
    required this.timestamp,
    required this.readingIndex,
    required this.prox1L,
    required this.prox2L,
    required this.prox1R,
    required this.prox2R,
    required this.ir,
  });

  @override
  String toString() {
    return 'SensorReading(${timestamp.toIso8601String()}, idx: $readingIndex, '
        'L1: $prox1L, L2: $prox2L, R1: $prox1R, R2: $prox2R, IR: $ir)';
  }
}

class SensorAverages {
  final double prox1L;
  final double prox2L;
  final double prox1R;
  final double prox2R;
  final double ir;

  const SensorAverages({
    required this.prox1L,
    required this.prox2L,
    required this.prox1R,
    required this.prox2R,
    required this.ir,
  });

  const SensorAverages.zero()
    : prox1L = 0,
      prox2L = 0,
      prox1R = 0,
      prox2R = 0,
      ir = 0;
}

// Usage example:
void main() {
  final sensorBuffer = SensorDataBuffer();

  // Process incoming data (call this every second)
  // sensorBuffer.processSensorData(dataReceived);

  // Access recent data
  // final lastReading = sensorBuffer.latestReading;
  // final last30Seconds = sensorBuffer.getReadingsInLastSeconds(30);
  // final averages = sensorBuffer.getAverages(10); // 10 second averages
}
