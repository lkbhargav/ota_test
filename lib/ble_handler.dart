import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:async';
import 'dart:typed_data';

enum ScanStatus {
  connectionTimeout,
  bluetoothAdapterNotAvailable,
  successful,
  somethingWentWrongScanning,
  notInitialized,
}

enum FileControlType {
  getFileSize,
  getNumberOfFiles,
  getVersion,
  initOTALeftCore,
  initOTARightCore,
  otaFileEndLeft,
  otaFileEndRight,
  resetOta,
}

typedef BLECallbackFn = Function(List<int>);
typedef BLEFileCallbackFn = Function(List<int>, FileControlType);

// Sensor service notify characteristics
const String sensorDataUUID = "12345678-1234-5678-1234-56789ABCDEF1";
const String batteryStatusUUID = "12345678-1234-5678-1234-56789ABCDEF3";
const String touchStatusUUID = "12345678-1234-5678-1234-56789ABCDEF4";
// Sensor service write characteristics
const String controlUUID = "12345678-1234-5678-1234-56789ABCDEF2";

// File service notify characteristics
const String metaDataUUID = "12345679-1234-5678-1234-56789ABCDEF2";
const String fileDataUUID = "12345679-1234-5678-1234-56789ABCDEF3";
// File service write characteristics
const String fileControlUUID = "12345679-1234-5678-1234-56789ABCDEF1";
const String otaDataUUID = "12345679-1234-5678-1234-56789ABCDEF4";

class BLEHandler {
  late Function(bool) _deviceStatusCallback;
  BLECallbackFn? _parseSensorData;
  BLECallbackFn? _parseBatteryData;
  BLECallbackFn? _parseTouchData;
  BLEFileCallbackFn? _parseMetaData;
  BLEFileCallbackFn? _parseFileData;
  bool _isInitialized = false;

  // send data to device
  BluetoothCharacteristic? maskControl;
  BluetoothCharacteristic? fileControl;
  BluetoothCharacteristic? otaData;

  bool _isConnected = false;
  Timer? _connectionTimer;
  bool connectToMask = true;

  // Subscription management
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;
  final List<StreamSubscription<List<int>>> _characteristicSubscriptions = [];
  BluetoothDevice? _peripheral;
  FileControlType? _cuurentFileControlRequest;

  // ota
  Timer? _waitingForAckTimer;

  void init(
    Function(bool) cBF,
    BLECallbackFn parseSensorData,
    BLECallbackFn parseBatteryData,
    BLECallbackFn parseTouchData,
    BLEFileCallbackFn parseMetaData,
    BLEFileCallbackFn parseFileData,
  ) {
    FlutterBluePlus.setLogLevel(LogLevel.none);
    FlutterBluePlus.setOptions(restoreState: true);

    _deviceStatusCallback = cBF;

    _parseSensorData = parseSensorData;
    _parseBatteryData = parseBatteryData;
    _parseTouchData = parseTouchData;
    _parseMetaData = parseMetaData;
    _parseFileData = parseFileData;

    _isInitialized = true;
  }

  Future<ScanStatus> scanAndConnect(
    String deviceId,
    Function(String) maskIdCallback,
    Function(ScanStatus)? connectStatusCallback,
  ) async {
    if (!_isInitialized) {
      return ScanStatus.notInitialized;
    }

    ScanStatus status = ScanStatus.successful;

    if (_connectionTimer != null) {
      _connectionTimer!.cancel();
    }

    _connectionTimer = Timer.periodic(Duration(seconds: 1), (t) async {
      if (_isConnected) {
        _connectionTimer!.cancel();

        if (connectStatusCallback != null) {
          // send a successfully connected message
          connectStatusCallback(ScanStatus.successful);
        }
      }

      if (t.tick >= 30) {
        _connectionTimer!.cancel();
        disconnect();

        if (connectStatusCallback != null) {
          // send a timeout message
          connectStatusCallback(ScanStatus.connectionTimeout);
        }
      }
    });

    try {
      // Check bluetooth adapter state
      await FlutterBluePlus.adapterState.first;

      _adapterStateSubscription = FlutterBluePlus.adapterState.listen((
        state,
      ) async {
        if (state == BluetoothAdapterState.on) {
          await FlutterBluePlus.stopScan();

          // Start scanning
          await _scanSubscription?.cancel();
          _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
            for (ScanResult r in results) {
              if (r.device.platformName.isEmpty) continue;

              // print(r.device.platformName);
              // r.device.platformName.contains(deviceId)
              // if (r.device.platformName.trim() == deviceId) {
              if (r.device.platformName.contains(deviceId)) {
                connect(r.device, maskIdCallback, r.device.remoteId.toString());
                return;
              }
            }
          });

          await FlutterBluePlus.startScan(
            timeout: const Duration(seconds: 300),
            androidUsesFineLocation: false,
          );
        } else {
          // adapter is turned off
          status = ScanStatus.bluetoothAdapterNotAvailable;
          return;
        }
      });
    } catch (e) {
      print('Error initializing Bluetooth: $e');
      return ScanStatus.somethingWentWrongScanning;
    }

    return status;
  }

  // Device connection
  Future<bool> connect(
    BluetoothDevice peripheral,
    Function(String) maskIdCallback,
    String remoteId,
  ) async {
    try {
      // Cancel scanning
      await FlutterBluePlus.stopScan();
      await _scanSubscription?.cancel();

      // Connect to device
      await peripheral.connect(
        timeout: const Duration(seconds: 10),
        autoConnect: false,
      );

      _peripheral = peripheral;

      _isConnected = true;

      maskIdCallback(remoteId);

      _deviceStatusCallback(true);

      // Discover services
      List<BluetoothService> services = await peripheral.discoverServices();
      for (BluetoothService service in services) {
        for (BluetoothCharacteristic characteristic
            in service.characteristics) {
          // Check for the write property
          if (characteristic.properties.write) {
            print(characteristic.uuid.toString());
            switch (characteristic.uuid.toString().toUpperCase()) {
              case controlUUID:
                print("Initialized mask control write characteristic");
                maskControl = characteristic;
                break;
              case fileControlUUID:
                print("Initialized file control write characteristic");
                fileControl = characteristic;
                break;
              case otaDataUUID:
                print("Initialized ota data write characteristic");
                otaData = characteristic;
                break;
            }
          }

          // Check for and set up notifications
          if (characteristic.properties.notify) {
            _characteristicSubscriptions.add(
              characteristic.onValueReceived.listen(
                (value) => _handleCharacteristicValue(characteristic, value),
                onError: (error) => {false},
              ),
            );
            await characteristic.setNotifyValue(true);
          }
        }
      }

      // Listen for disconnection
      peripheral.connectionState.listen((BluetoothConnectionState state) {
        if (state == BluetoothConnectionState.disconnected) {
          handleDisconnect();
        }
      });
    } catch (e) {
      print('Failed to connect: $e');
      handleDisconnect();
      return false;
    }

    return true;
  }

  bool isConnected() {
    return _isConnected;
  }

  // Manage disconnection to device
  void handleDisconnect() {
    disconnect();

    _isConnected = false;

    // Attempt to reconnect
    init(
      _deviceStatusCallback,
      _parseSensorData!,
      _parseBatteryData!,
      _parseTouchData!,
      _parseMetaData!,
      _parseFileData!,
    );
  }

  // TODO: fix this disconnect method, it seems to stream data even after the charactersticSubscription is cancelled
  Future<void> disconnect() async {
    _isConnected = false;

    _deviceStatusCallback(false);

    try {
      for (var characterstic in _characteristicSubscriptions) {
        await characterstic.cancel();
      }
      await _adapterStateSubscription?.cancel();
      await _scanSubscription?.cancel();

      await FlutterBluePlus.stopScan();

      if (_peripheral != null) {
        await _peripheral!.disconnect();
      }
    } catch (e) {
      print("Error cancelling subscriptions: $e");
    }
  }

  // Process incoming data using batch manager
  void _handleCharacteristicValue(
    BluetoothCharacteristic characteristic,
    List<int> value,
  ) {
    _deviceStatusCallback(true);

    switch (characteristic.characteristicUuid.toString().toUpperCase()) {
      case sensorDataUUID:
        _parseSensorData!(value);
        break;
      case batteryStatusUUID:
        _parseBatteryData!(value);
        break;
      case touchStatusUUID:
        _parseTouchData!(value);
        break;
      case metaDataUUID:
        _parseMetaData!(value, _cuurentFileControlRequest!);
        break;
      case fileDataUUID:
        _parseFileData!(value, _cuurentFileControlRequest!);
        break;
    }
  }

  String _toHexaDecimalString(List<int> data) {
    String hexString = data
        .map((n) {
          return n
              .toRadixString(16)
              .padLeft(2, '0'); // Convert to hex and pad to 2 characters
        })
        .join('');

    return hexString;
  }

  // Update settings and get data
  Future<bool> updateSettings(List<int> writeArr) async {
    if (_isConnected && maskControl != null) {
      try {
        await maskControl!.write(writeArr, withoutResponse: false);
      } catch (e) {
        print('Failed to write characteristic: $e');
        return false;
      }
    } else {
      return false;
    }

    return true;
  }

  Future<bool> sendFileControl(FileControlType fct) async {
    List<int>? instruction;

    // TODO: update all the instruction values

    switch (fct) {
      case FileControlType.getFileSize:
        instruction = [51, 0, 0, 0, 0];
        break;
      case FileControlType.getNumberOfFiles:
        instruction = [52, 0, 0, 0, 0];
        break;
      case FileControlType.getVersion:
        instruction = [53, 0, 0, 0, 0];
        break;
      case FileControlType.initOTALeftCore:
        instruction = [54, 0, 0, 0, 0];
        break;
      case FileControlType.initOTARightCore:
        instruction = [54, 0, 0, 0, 1];
        break;
      case FileControlType.otaFileEndLeft:
        instruction = [54, 100, 0, 0, 0];
        break;
      case FileControlType.otaFileEndRight:
        instruction = [54, 100, 0, 0, 1];
        break;
      case FileControlType.resetOta:
        instruction = [54, 200, 0, 0, 0];
        break;
    }

    _cuurentFileControlRequest = fct;

    try {
      await fileControl!.write(
        Uint8List.fromList(instruction),
        withoutResponse: false,
      );
    } catch (e) {
      // TODO: log the error with appLogs
      print("Error writting: $e");
      return false;
    }

    return true;
  }

  Future<bool> sendOTAData(ByteData bd, Function() timeoutCallback) async {
    if (otaData == null) {
      return false;
    }

    otaData!.write(bd.buffer.asUint8List(), withoutResponse: false);

    // defining the timeout for the write
    _waitingForAckTimer = Timer(Duration(seconds: 10), () {
      timeoutCallback();
    });

    return true;
  }

  void otaAckReceived() {
    if (_waitingForAckTimer == null) {
      return;
    }

    _waitingForAckTimer!.cancel();
  }

  // CLEANUP METHOD for when disposing of BLE Handler
  Future<void> dispose() async {
    try {
      await disconnect();
    } catch (e) {
      print('Error during disposal: $e');
    }
  }
}
