import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  final firstCamera = cameras.first;

  runApp(
    MaterialApp(
      home: BrailleRecognition(camera: firstCamera),
    ),
  );
}

class BrailleRecognition extends StatefulWidget {
  final CameraDescription camera;

  const BrailleRecognition({required this.camera});

  @override
  _BrailleRecognitionState createState() => _BrailleRecognitionState();
}

class _BrailleRecognitionState extends State<BrailleRecognition> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  late Interpreter _interpreter;
  String _recognitionResult = "Awaiting result...";
  final int inputSize = 640; // 입력 크기를 줄여서 성능 향상
  bool _isProcessing = false;
  int _frameCount = 0;
  final int _frameInterval = 5; // 프레임 드롭 간격

  @override
  void initState() {
    super.initState();
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.medium, // 해상도를 낮춰 성능 향상
    );
    _initializeControllerFuture = _controller.initialize();
    loadModel();
  }

  @override
  void dispose() {
    _controller.dispose();
    _interpreter.close();
    super.dispose();
  }

  Future<void> loadModel() async {
    var options = InterpreterOptions()..useNnApiForAndroid = true; // NNAPI 사용
    _interpreter = await Interpreter.fromAsset('assets/detected_braille_m.tflite', options: options);
  }

  void processCameraImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    var startTime = DateTime.now();

    try {
      var detectionResult = await compute(_runDetection, {
        'image': image,
        'inputSize': inputSize,
        'interpreterAddress': _interpreter.address,
      });

      setState(() {
        if (detectionResult.isNotEmpty) {
          _recognitionResult = "Detection successful";
        } else {
          _recognitionResult = "No objects detected";
        }
      });
    } catch (e) {
      setState(() {
        _recognitionResult = "Error: $e";
      });
      developer.log('Error during recognition: $e', name: 'BrailleRecognition');
    } finally {
      _isProcessing = false;
      developer.log('Total processing time: ${DateTime.now().difference(startTime).inMilliseconds} ms', name: 'BrailleRecognition');
    }
  }

  static Future<List<Map<String, dynamic>>> _runDetection(Map<String, dynamic> params) async {
    CameraImage image = params['image'];
    int inputSize = params['inputSize'];
    int interpreterAddress = params['interpreterAddress'];

    var startTime = DateTime.now();

    // Convert CameraImage to Image package format
    var startTimeConvert = DateTime.now();
    final int width = image.width;
    final int height = image.height;
    final img.Image convertedImage = img.Image.fromBytes(
      width,
      height,
      image.planes[0].bytes,
      format: img.Format.luminance,
    );

    // Resize the image
    var resizedImage = img.copyResize(convertedImage, width: inputSize, height: inputSize);

    // Convert image to tensor
    var input = List.generate(inputSize, (i) => List.generate(inputSize, (j) => List.filled(3, 0.0)));
    for (int i = 0; i < inputSize; i++) {
      for (int j = 0; j < inputSize; j++) {
        var pixel = resizedImage.getPixel(j, i);
        input[i][j][0] = img.getRed(pixel) / 255.0;
        input[i][j][1] = img.getGreen(pixel) / 255.0;
        input[i][j][2] = img.getBlue(pixel) / 255.0;
      }
    }
    var output = List.generate(1, (i) => List.generate(25200, (j) => List.filled(6, 0.0)));

    // Create interpreter instance in the isolate
    var interpreter = Interpreter.fromAddress(interpreterAddress);
    interpreter.run([input], output);

    var detections = _parseDetections(output, inputSize);

    return detections;
  }

  static List<Map<String, dynamic>> _parseDetections(List<List<List<double>>> output, int inputSize) {
    var detections = <Map<String, dynamic>>[];

    for (var i = 0; i < output[0].length; i++) {
      var detection = output[0][i];
      var score = detection[4];
      if (score > 0.25) {
        var bbox = detection.sublist(0, 4).map((e) => (e * inputSize).toInt()).toList();
        var label = detection[5].toInt();
        detections.add({'label': label, 'score': score, 'bbox': bbox});
      }
    }

    return detections;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Braille Recognition')),
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            if (!_controller.value.isStreamingImages) {
              _controller.startImageStream((CameraImage image) {
                _frameCount++;
                if (_frameCount % _frameInterval == 0) {
                  processCameraImage(image);
                }
              });
            }
            return Stack(
              children: [
                CameraPreview(_controller),
                Positioned(
                  bottom: 10,
                  left: 10,
                  child: Container(
                    padding: EdgeInsets.all(10),
                    color: Colors.white,
                    child: Text('Recognition Result: $_recognitionResult'),
                  ),
                ),
              ],
            );
          } else {
            return Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }
}
