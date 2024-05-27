import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';
import 'dart:math';

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
  List<Map<String, dynamic>> _detectionResults = [];

  @override
  void initState() {
    super.initState();
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.medium, // 해상도를 낮춰 성능 향상
    );
    _initializeControllerFuture = _controller.initialize();
    _initializeControllerFuture.then((_) {
      if (mounted) {
        _controller.startImageStream((CameraImage image) {
          _frameCount++;
          if (_frameCount % _frameInterval == 0) {
            processCameraImage(image);
          }
        });
      }
    });
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

  void processCameraImage(CameraImage? image) async {
    if (image == null || _isProcessing) return;
    _isProcessing = true;

    var startTime = DateTime.now();

    try {
      developer.log('Processing image frame', name: 'BrailleRecognition');
      var detectionResult = await compute(_runDetection, {
        'image': image,
        'inputSize': inputSize,
        'interpreterAddress': _interpreter.address,
      });

      setState(() {
        if (detectionResult.isNotEmpty) {
          _recognitionResult = "Detection successful";
          _detectionResults = detectionResult;
          developer.log('Detection Results: $_detectionResults', name: 'BrailleRecognition');
        } else {
          _recognitionResult = "No objects detected";
          _detectionResults = [];
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
    final int numChannels = image.planes.length;

    // Convert the image to RGB if it's not already
    img.Image convertedImage;
    if (numChannels == 1) {
      convertedImage = img.Image.fromBytes(
        width,
        height,
        image.planes[0].bytes,
        format: img.Format.luminance,
      );
    } else {
      convertedImage = img.Image(width, height);
      for (int plane = 0; plane < numChannels; plane++) {
        final bytes = image.planes[plane].bytes;
        final bytesPerRow = image.planes[plane].bytesPerRow;
        final bytesPerPixel = (bytesPerRow / width).round();
        for (int y = 0; y < height; y++) {
          for (int x = 0; x < width; x++) {
            final index = y * bytesPerRow + x * bytesPerPixel;
            if (index < bytes.length) {
              final pixel = bytes[index];
              if (plane == 0) {
                convertedImage.setPixel(x, y, img.getColor(pixel, 0, 0));
              } else if (plane == 1) {
                final existingPixel = convertedImage.getPixel(x, y);
                convertedImage.setPixel(x, y, img.getColor(img.getRed(existingPixel), pixel, 0));
              } else if (plane == 2) {
                final existingPixel = convertedImage.getPixel(x, y);
                convertedImage.setPixel(x, y, img.getColor(img.getRed(existingPixel), img.getGreen(existingPixel), pixel));
              }
            }
          }
        }
      }
    }

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

    return _applyNonMaxSuppression(detections, 0.25, 0.45);
  }

  static List<Map<String, dynamic>> _parseDetections(List<List<List<double>>> output, int inputSize) {
    var detections = <Map<String, dynamic>>[];

    var rng = Random();
    for (var i = 0; i < output[0].length; i++) {
      var detection = output[0][i];
      var score = detection[4];
      if (score > 0.25) {
        var bbox = detection.sublist(0, 4).map((e) => (e * inputSize).toInt()).toList();
        var label = detection[5].toInt();
        var color = Color.fromARGB(255, rng.nextInt(256), rng.nextInt(256), rng.nextInt(256));
        detections.add({'label': label, 'score': score, 'bbox': bbox, 'color': color});
      }
    }

    return detections;
  }

  static List<Map<String, dynamic>> _applyNonMaxSuppression(
      List<Map<String, dynamic>> detections, double scoreThreshold, double iouThreshold) {
    detections.sort((a, b) => b['score'].compareTo(a['score']));
    var finalDetections = <Map<String, dynamic>>[];

    while (detections.isNotEmpty) {
      var best = detections.removeAt(0);
      finalDetections.add(best);

      detections = detections.where((detection) {
        var iou = _calculateIoU(best['bbox'], detection['bbox']);
        return iou < iouThreshold;
      }).toList();
    }

    return finalDetections;
  }

  static double _calculateIoU(List<int> boxA, List<int> boxB) {
    var xA = max(boxA[0], boxB[0]);
    var yA = max(boxA[1], boxB[1]);
    var xB = min(boxA[2], boxB[2]);
    var yB = min(boxA[3], boxB[3]);

    var interArea = max(0, xB - xA + 1) * max(0, yB - yA + 1);
    var boxAArea = (boxA[2] - boxA[0] + 1) * (boxA[3] - boxA[1] + 1);
    var boxBArea = (boxB[2] - boxB[0] + 1) * (boxB[3] - boxB[1] + 1);

    return interArea / (boxAArea + boxBArea - interArea);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Braille Recognition')),
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final double width = constraints.maxWidth;
                final double height = constraints.maxHeight;
                return Stack(
                  children: [
                    CameraPreview(_controller),
                    CustomPaint(
                      painter: BoundingBoxPainter(_detectionResults, width, height),
                      child: Container(),
                    ),
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
              },
            );
          } else {
            return Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }
}

class BoundingBoxPainter extends CustomPainter {
  final List<Map<String, dynamic>> detections;
  final double screenWidth;
  final double screenHeight;

  BoundingBoxPainter(this.detections, this.screenWidth, this.screenHeight);

  @override
  void paint(Canvas canvas, Size size) {
    for (var detection in detections) {
      var bbox = detection['bbox'];
      var color = detection['color'] as Color;
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      double scaleX = screenWidth / 640; // 640은 입력 이미지 크기
      double scaleY = screenHeight / 640; // 640은 입력 이미지 크기

      var rect = Rect.fromLTRB(
        bbox[0].toDouble() * scaleX,
        bbox[1].toDouble() * scaleY,
        bbox[2].toDouble() * scaleX,
        bbox[3].toDouble() * scaleY,
      );
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}
