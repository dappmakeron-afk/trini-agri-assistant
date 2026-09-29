import 'package:speech_to_text/speech_to_text.dart';

class VoiceService {
  final SpeechToText speech = SpeechToText();

  Future<bool> init() async => await speech.initialize();

  void listen(Function(String) onResult) {
    speech.listen(onResult: (result) {
      if (result.finalResult) {
        onResult(result.recognizedWords);
      }
    });
  }

  void stop() => speech.stop();
}