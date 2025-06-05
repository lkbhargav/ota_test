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

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  @override
  void initState() {
    super.initState();

    _bleHandler.init(
      (v) {
        // print("Callback: $v");
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
      (v, w) {
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

          dataReceived = ReceivedData(checksumReceived, index);
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
      "NoctABC",
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
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            ElevatedButton(
              child: Text("Perform OTA"),
              onPressed: () async {
                // if (!fileInitialized) {
                await _bleHandler.sendFileControl(
                  FileControlType.initOTALeftCore,
                );
                var fileContent = await rootBundle.load('assets/ota_left.bin');

                _ota = OtaRelated(fileContent);
                // fileInitialized = true;
                // return;
                // }

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
                    var index = _ota.getIndex() - 1;

                    print(
                      "Checksum received: ${receivedData.checksum} (${receivedData.index}) | Computed checksum: $checksumComputed ($index)",
                    );

                    if (receivedData.checksum == checksumComputed &&
                        index == receivedData.index) {
                      print("Checksum and index matches!");
                      _bleHandler.otaAckReceived();

                      dataReceived = null;
                      dataSent = false;
                    } else {
                      // TODO: send out a reset signal
                      print(
                        "Aborting the update, something is off with checksum's or index",
                      );
                      _bleHandler.sendFileControl(FileControlType.resetOta);
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
                    _bleHandler.sendFileControl(FileControlType.otaFileEndLeft);
                    break;
                  }

                  await _bleHandler.sendOTAData(resp.$1!, () {
                    // perform reset operations on the _ota
                    print("Reached the 10s timeout!");
                    _bleHandler.sendFileControl(FileControlType.resetOta);
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
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}
