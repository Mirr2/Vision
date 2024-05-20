import 'package:tflite/tflite.dart';

class TFLiteModel {
  Future<void> loadModel() async {
    await Tflite.loadModel(
      model: "assets/detected_braille_m.tflite", // 모델 파일 경로
    );
  }

  Future<List<dynamic>?> runModelOnFrame(CameraImage image) async {
    return await Tflite.runModelOnFrame(
      bytesList: image.planes.map((plane) => plane.bytes).toList(),
      imageHeight: image.height,
      imageWidth: image.width,
    );
  }

  void dispose() {
    Tflite.close();
  }
}
