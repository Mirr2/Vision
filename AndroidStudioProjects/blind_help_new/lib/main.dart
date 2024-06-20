import 'dart:developer' as developer;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';
import 'dart:math';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'dart:io';
import 'package:flutter_tts/flutter_tts.dart';
import 'dart:convert'; // 추가

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  final firstCamera = cameras.first;

  // Test if the asset can be loaded
  try {
    final data = await rootBundle.load('assets/alarm.mp3');
    print('Asset loaded successfully');
  } catch (e) {
    print('Error loading asset: $e');
  }

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
  late AudioPlayer _audioPlayer;
  late FlutterTts _flutterTts;
  String _recognitionResult = "Awaiting result...";
  final int inputSize = 640; // 입력 크기를 줄여서 성능 향상
  bool _isProcessing = false;
  int _frameCount = 0;
  final int _frameInterval = 2; // 프레임 드롭 간격

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
    }).catchError((error) {
      developer.log('Error initializing camera: $error');
    });
    loadModel();
    _audioPlayer = AudioPlayer();
    _flutterTts = FlutterTts();
    _requestPermissions();
  }

  @override
  void dispose() {
    _controller.dispose();
    _interpreter.close();
    _audioPlayer.dispose();
    _flutterTts.stop();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.storage,
      Permission.accessMediaLocation,
    ].request();

    if (statuses[Permission.storage] != PermissionStatus.granted) {
      developer.log('Storage permission is not granted');
    }

    if (statuses[Permission.accessMediaLocation] != PermissionStatus.granted) {
      developer.log('Access media location permission is not granted');
    }
  }

  Future<void> loadModel() async {
    var options = InterpreterOptions()..useNnApiForAndroid = true; // NNAPI 사용
    _interpreter = await Interpreter.fromAsset('assets/detected_braille_m.tflite', options: options);
    developer.log('Model loaded successfully');
  }

  void processCameraImage(CameraImage? image) async {
    if (image == null || _isProcessing) return;
    _isProcessing = true;

    var startTime = DateTime.now();

    try {
      developer.log('Processing image frame', name: 'BrailleRecognition');
      var detectionResults = await compute(_runDetection, {
        'image': image,
        'inputSize': inputSize,
        'interpreterAddress': _interpreter.address,
      });

      setState(() {
        if (detectionResults.isNotEmpty) {
          _recognitionResult = "Detection successful";
          // Play notification sound
          playSound();
          // Convert CameraImage to File and upload to server
          uploadImage(convertCameraImageToFile(image));
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

  void playSound() async {
    try {
      // Load the audio file as a byte buffer
      final ByteData data = await rootBundle.load('assets/alarm.mp3');
      final Uint8List bytes = data.buffer.asUint8List();

      // Play the sound from the byte buffer
      await _audioPlayer.play(BytesSource(bytes));
    } catch (e) {
      developer.log('Error playing sound: $e', name: 'BrailleRecognition');
    }
  }

  static Future<List<Map<String, dynamic>>> _runDetection(Map<String, dynamic> params) async {
    CameraImage image = params['image'];
    int inputSize = params['inputSize'];
    int interpreterAddress = params['interpreterAddress'];

    var startTime = DateTime.now();
    developer.log('Running detection', name: 'BrailleRecognition');

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
            final int index = y * bytesPerRow + x * bytesPerPixel;
            if (index < bytes.length) {
              final int pixel = bytes[index];
              int r = 0, g = 0, b = 0;

              if (plane == 0) {
                r = pixel;
              } else if (plane == 1) {
                g = pixel;
              } else if (plane == 2) {
                b = pixel;
              }

              final existingPixel = convertedImage.getPixel(x, y);
              convertedImage.setPixel(x, y, img.getColor(r + img.getRed(existingPixel), g + img.getGreen(existingPixel), b + img.getBlue(existingPixel)));
            }
          }
        }
      }
    }

    // Log the converted image dimensions
    developer.log('Converted image dimensions: ${convertedImage.width}x${convertedImage.height}', name: 'BrailleRecognition');

    // Resize the image
    var resizedImage = img.copyResize(convertedImage, width: inputSize, height: inputSize);

    // Log the resized image dimensions
    developer.log('Resized image dimensions: ${resizedImage.width}x${resizedImage.height}', name: 'BrailleRecognition');

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

    // Log a sample input tensor value
    developer.log('Sample input tensor value: ${input[0][0]}', name: 'BrailleRecognition');

    var output = List.generate(1, (i) => List.generate(25200, (j) => List.filled(6, 0.0)));

    // Create interpreter instance in the isolate
    var interpreter = Interpreter.fromAddress(interpreterAddress);
    interpreter.run([input], output);

    var detections = _parseDetections(output, inputSize);
    developer.log('Detection complete', name: 'BrailleRecognition');

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
        detections.add({
          'label': label,
          'score': score,
          'bbox': bbox,
          'color': color,
        });

        // Log each detection
        developer.log('Detection: label=$label, score=$score, bbox=$bbox', name: 'BrailleRecognition');
      }
    }

    return detections;
  }

  static List<Map<String, dynamic>> _applyNonMaxSuppression(List<Map<String, dynamic>> detections, double iouThreshold, double scoreThreshold) {
    detections.sort((a, b) => b['score'].compareTo(a['score']));

    var suppressed = List<bool>.filled(detections.length, false);
    var results = <Map<String, dynamic>>[];

    for (var i = 0; i < detections.length; i++) {
      if (suppressed[i]) continue;

      var a = detections[i];
      results.add(a);

      for (var j = i + 1; j < detections.length; j++) {
        if (suppressed[j]) continue;

        var b = detections[j];
        if (_calculateIoU(a['bbox'], b['bbox']) > iouThreshold) {
          suppressed[j] = true;
        }
      }
    }

    return results;
  }

  static double _calculateIoU(List<int> boxA, List<int> boxB) {
    var xA = max(boxA[0], boxB[0]);
    var yA = max(boxA[1], boxB[1]);
    var xB = min(boxA[2], boxB[2]);
    var yB = min(boxA[3], boxB[3]);

    var interArea = max(0, xB - xA + 1) * max(0, yA - yB + 1);
    var boxAArea = (boxA[2] - boxA[0] + 1) * (boxA[3] - boxA[1] + 1);
    var boxBArea = (boxB[2] - boxB[0] + 1) * (boxB[3] - boxB[1] + 1);

    return interArea / (boxAArea + boxBArea - interArea);
  }

  img.Image convertCameraImage(CameraImage image) {
    final int width = image.width;
    final int height = image.height;

    // 카메라 이미지 포맷에 맞게 변환
    if (image.format.group == ImageFormatGroup.yuv420) {
      final int uvRowStride = image.planes[1].bytesPerRow;
      final int uvPixelStride = image.planes[1].bytesPerPixel!;

      final img.Image rgbImage = img.Image(width, height);

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final int uvIndex = uvPixelStride * (x / 2).floor() + uvRowStride * (y / 2).floor();
          final int index = y * width + x;

          final int yValue = image.planes[0].bytes[index];
          final int uValue = image.planes[1].bytes[uvIndex];
          final int vValue = image.planes[2].bytes[uvIndex];

          final int r = (yValue + (1.370705 * (vValue - 128))).toInt().clamp(0, 255);
          final int g = (yValue - (0.337633 * (uValue - 128)) - (0.698001 * (vValue - 128))).toInt().clamp(0, 255);
          final int b = (yValue + (1.732446 * (uValue - 128))).toInt().clamp(0, 255);

          rgbImage.setPixel(x, y, img.getColor(r, g, b));
        }
      }

      return rgbImage;
    } else {
      throw Exception('Unsupported image format');
    }
  }

  File convertCameraImageToFile(CameraImage image) {
    final img.Image convertedImage = convertCameraImage(image);
    final List<int> pngBytes = img.encodePng(convertedImage);

    final Directory tempDir = Directory.systemTemp;
    final String tempPath = tempDir.path;
    final File tempFile = File('$tempPath/frame_${DateTime.now().millisecondsSinceEpoch}.png');

    tempFile.writeAsBytesSync(pngBytes);
    return tempFile;
  }

  Future<void> uploadImage(File image) async {
    if (image == null) {
      print("#1, image ---> null");
      return;
    }

    try {
      final uri = Uri.parse('http://172.18.25.33:5000/detect'); // 서버 IP 주소 확인
      print("#2, URI created: $uri");

      final request = http.MultipartRequest('POST', uri)
        ..files.add(await http.MultipartFile.fromPath('file', image.path));
      print("#3, Request prepared");

      try {
        print("#4, Sending request");
        final response = await request.send().timeout(const Duration(seconds: 10), onTimeout: () {
          print("#4a, Request timeout");
          return http.StreamedResponse(Stream.empty(), 408); // HTTP 408 Request Timeout
        });
        print("#5, Request sent");

        final responseString = await response.stream.bytesToString();
        print("#6, Response received: $responseString");

        if (response.statusCode == 200) {
          print('Image uploaded successfully. Response: $responseString');
          // Speak the result
          _speak("점자가 감지되었습니다. " + jsonDecode(responseString)['result'].join(", "));
        } else if (response.statusCode == 404) {
          print('Failed to upload image. Status code: ${response.statusCode}');
          print('Response: $responseString');
          _speak("점자가 아닙니다.");
        } else {
          print('Failed to upload image. Status code: ${response.statusCode}');
          print('Response: $responseString');
        }
      } catch (e) {
        print('Error uploading image: $e');
      }
    } catch (e) {
      print('#5 URI: $e');
    }
  }

  Future<void> _speak(String text) async {
    await _flutterTts.speak(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Visionary Bridge',
          style: TextStyle(color: Colors.blueAccent), // Change the text color here
        ),
        centerTitle: true,
      ),
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Column(
              children: [
                Expanded(
                  child: CameraPreview(_controller),
                ),
                Container(
                  padding: EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(20.0),
                      topRight: Radius.circular(20.0),
                    ),
                  ),
                  child: Text('Recognition Result: $_recognitionResult'),
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
