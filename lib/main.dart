import 'package:flutter/material.dart';
import 'camera/camera_stream.dart';
import 'package:camera/camera.dart'; // Import the camera package

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await cameraStream.initializeCamera();

  runApp(MyApp());
}

final CameraStream cameraStream = CameraStream();

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '점자 인식기',
      theme: ThemeData.dark(),
      home: CameraScreen(),
    );
  }
}

class CameraScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('카메라 화면')),
      body: FutureBuilder<void>(
        future: cameraStream.initializeCamera(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return CameraPreview(cameraStream.controller); // Use CameraPreview
          } else {
            return Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }
}
