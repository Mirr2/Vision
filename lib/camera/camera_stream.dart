import 'package:camera/camera.dart';

class CameraStream {
  late CameraController _controller;

  Future<void> initializeCamera() async {
    final cameras = await availableCameras();
    _controller = CameraController(
      cameras.first,
      ResolutionPreset.medium,
    );
    await _controller.initialize();
  }

  CameraController get controller => _controller;
}
