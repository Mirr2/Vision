import 'package:flutter_tts/flutter_tts.dart';

class TextToSpeech {
  final FlutterTts _tts = FlutterTts();

  Future<void> speak(String text) async {
    await _tts.speak(text); // 텍스트를 음성으로 출력
  }

  void dispose() {
    _tts.stop(); // TTS 멈추기
  }
}
