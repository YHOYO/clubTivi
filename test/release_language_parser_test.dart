import 'package:clubtivi/data/models/language_preferences.dart';
import 'package:clubtivi/data/services/release_language_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cases = <({String release, Set<String> audio, Set<String> subtitles})>[
    (
      release: 'Movie.2024.1080p.WEB-DL.Latino.mkv',
      audio: {kLanguageSpanishLatin},
      subtitles: <String>{},
    ),
    (
      release: 'Movie.2024.CASTELLANO.1080p.BluRay',
      audio: {kLanguageSpanish},
      subtitles: <String>{},
    ),
    (
      release: 'Movie.2024.MULTI.1080p.WEB-DL',
      audio: {kLanguageSpanish, kLanguageEnglish},
      subtitles: <String>{},
    ),
    (
      release: 'Movie.2024.VOSE.1080p',
      audio: <String>{},
      subtitles: {kLanguageSpanish},
    ),
    (
      release: 'Movie.2024.English.1080p',
      audio: {kLanguageEnglish},
      subtitles: <String>{},
    ),
    (
      release: 'Serie.S01E02.ESPANOL.LATINO.SUBTITULADO',
      audio: {kLanguageSpanishLatin},
      subtitles: {kLanguageSpanish},
    ),
    (
      release: 'Movie.2024.1080p.WEB-DL.DDP5.1.H.264-GROUP',
      audio: <String>{},
      subtitles: <String>{},
    ),
  ];

  for (final testCase in cases) {
    test('parsea ${testCase.release}', () {
      final parsed = ReleaseLanguageParser.parse(testCase.release);

      expect(parsed.audio, testCase.audio);
      expect(parsed.subtitles, testCase.subtitles);
    });
  }
}
