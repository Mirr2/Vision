import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    cameraStream.controller.startImageStream((image) async {
      final output = await tfliteModel.runModelOnFrame(image);
      if (output != null) {
        final text = brailleRecognition.recognizeBraille(output);
        await textToSpeech.speak("오른쪽 방향에 점자가 있습니다. $text 입니다.");
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RawKeyboardListener(
        focusNode: FocusNode(),
        onKey: (event) {
          if (event.isKeyPressed(LogicalKeyboardKey.space)) {
            _initialize();
          }
        },
        child: Center(
          child: Text(
            '점자 인식기를 시작하려면 스페이스바를 누르세요.',
            style: TextStyle(fontSize: 24),
          ),
        ),
      ),
    );
  }
}
