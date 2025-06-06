import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:n2v2_test/ble_handler.dart';
import 'package:n2v2_test/ota_related.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class ReceivedData {
  String checksum;
  int index;

  ReceivedData(this.checksum, this.index);
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;
  final BLEHandler _bleHandler = BLEHandler();
  late OtaRelated _ota;
  bool fileInitialized = false;
  ReceivedData? dataReceived;
  bool _otaTimedOut = false;
  List<String> list = ["1", "2", "3", "Custom"];
  String dropdownValue = "1";
  final TextEditingController _deviceIdController = TextEditingController();
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();

    _deviceIdController.text = "NocturnalCheck";

    _bleHandler.init(
      (v) {
        print("In connection callback: $v");
        setState(() {
          _isConnected = v;
        });
      },
      (v) {
        // print("Sensor data: $v");
      },
      (v) {
        // print("Battery data: $v");
      },
      (v) {
        // print("Touch data: $v");
      },
      (v, w) async {
        print("Meta data: $v | File control type: $w");
        if (v[0] == 100 && v[1] == 2) {
          List<int> indexData = v.sublist(v.length - 6, v.length - 4);
          List<int> lastFour = v.sublist(v.length - 4);

          int index = (indexData[0] << 8) | (indexData[1]);

          // Convert to a byte buffer in big-endian
          int result =
              (lastFour[0] << 24) |
              (lastFour[1] << 16) |
              (lastFour[2] << 8) |
              lastFour[3];

          var checksumReceived = result.toRadixString(16).padLeft(8, '0');

          if (checksumReceived == "00000000") {
            var resp = _ota.getCurrentChunk();

            if (resp.$1 != null) {
              print(resp.$1!.buffer.asUint8List());
            }

            await _bleHandler.sendOTAData(resp.$1!, () {
              // perform reset operations on the _ota
              print("Reached the 10s timeout!");
              _bleHandler.sendFileControl(FileControlType.resetOta);
              _otaTimedOut = true;
            });
          } else {
            dataReceived = ReceivedData(checksumReceived, index);
          }
        }
      },
      (v, w) {
        print("File data: $v | File control type: $w");
      },
    );

    scanAndConnect();
  }

  void scanAndConnect() async {
    await _bleHandler.scanAndConnect(
      _deviceIdController.text,
      (id) {
        print("Mask ID (maskIdCallback): $id");
      },
      (cs) {
        print("Connection status: $cs");
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    print("isConnected: $_isConnected");
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text('You are ${_isConnected ? 'Connected' : 'Disconnected'}'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            SizedBox(height: 20),
            DropdownButton<String>(
              value: dropdownValue,
              icon: const Icon(Icons.arrow_downward),
              elevation: 16,
              style: const TextStyle(color: Colors.deepPurple),
              underline: Container(height: 2, color: Colors.deepPurpleAccent),
              onChanged: (String? value) {
                // This is called when the user selects an item.
                setState(() {
                  dropdownValue = value!;
                });
              },
              items:
                  list.map<DropdownMenuItem<String>>((String value) {
                    return DropdownMenuItem<String>(
                      value: value,
                      child: Text(value),
                    );
                  }).toList(),
            ),
            SizedBox(height: 20),
            SizedBox(
              width: 250,
              child: TextField(
                controller: _deviceIdController,
                decoration: const InputDecoration(
                  labelText: 'Enter deviceID',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              child: Text("Scan and connect"),
              onPressed: () {
                scanAndConnect();
              },
            ),
            SizedBox(height: 20),
            ElevatedButton(
              child: Text("Perform OTA"),
              onPressed:
                  !_isConnected
                      ? null
                      : () async {
                        var filename = 'assets/ota_left.bin';

                        switch (dropdownValue) {
                          case '2':
                            filename = 'assets/mkrzerol.bin';
                            break;
                          case '3':
                            filename = 'assets/wbootloader.bin';
                            break;
                        }

                        var fileContent;

                        if (dropdownValue == 'Custom') {
                          final result = await FilePicker.platform.pickFiles();

                          if (result == null || result.files.isEmpty) {
                            return;
                          }

                          final file = result.files.first;
                          if (file.path == null) return;

                          final bytes = await File(file.path!).readAsBytes();
                          fileContent = ByteData.view(bytes.buffer);
                        } else {
                          fileContent = await rootBundle.load(filename);
                        }

                        await _bleHandler.sendFileControl(
                          FileControlType.initOTALeftCore,
                        );

                        _ota = OtaRelated(fileContent);

                        var dataSent = false;

                        while (true) {
                          if (_otaTimedOut) {
                            _otaTimedOut = false;
                            break;
                          }

                          if (dataSent) {
                            if (dataReceived == null) {
                              await Future.delayed(Duration(milliseconds: 10));
                              continue;
                            }

                            var receivedData = dataReceived!;

                            var checksumComputed = _ota.crc32();
                            var index = _ota.getIndex();

                            print(
                              "Checksum received: ${receivedData.checksum} (${receivedData.index}) | Computed checksum: $checksumComputed ($index)",
                            );

                            if (index == receivedData.index) {
                              // if (receivedData.checksum == checksumComputed &&
                              //     index == receivedData.index) {
                              print("Checksum and index matches!");
                              _bleHandler.otaAckReceived();

                              dataReceived = null;
                              dataSent = false;
                            } else {
                              // TODO: send out a reset signal
                              print(
                                "Aborting the update, something is off with checksum's or index",
                              );
                              _bleHandler.sendFileControl(
                                FileControlType.resetOta,
                              );
                              break;
                            }

                            await Future.delayed(Duration(milliseconds: 10));
                            continue;
                          }

                          // if (fileInitialized) {
                          var resp = _ota.getNextChunk();

                          if (resp.$1 != null) {
                            print(resp.$1!.buffer.asUint8List());
                          }

                          if (resp.$2 == ChunkStatus.end) {
                            print("End of file");
                            _bleHandler.sendFileControl(
                              FileControlType.otaFileEndLeft,
                            );
                            break;
                          }

                          await _bleHandler.sendOTAData(resp.$1!, () {
                            // perform reset operations on the _ota
                            print("Reached the 10s timeout!");
                            _bleHandler.sendFileControl(
                              FileControlType.resetOta,
                            );
                            _otaTimedOut = true;
                          });

                          setState(() {
                            _counter = _ota.getIndex();
                          });

                          dataSent = true;
                        }
                      },
            ),
          ],
        ),
      ),
    );
  }
}
