import 'package:clubtivi/features/player/buffer_progress.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lector de propiedades falso: devuelve lo que se le diga y cuenta las
/// consultas por nombre, para poder comprobar qué se sondea.
class _FakeMpv {
  final Map<String, String> values;
  final List<String> asked = [];

  _FakeMpv([Map<String, String>? initial]) : values = {...?initial};

  Future<String?> read(String name) async {
    asked.add(name);
    return values[name];
  }
}

void main() {
  group('BufferProgress', () {
    test('sin datos de mpv no inventa porcentaje', () {
      const progress = BufferProgress(
        phase: BufferPhase.connecting,
        waited: Duration(milliseconds: 3400),
      );

      expect(progress.fill, isNull);
      expect(progress.describe(), 'Conectando… 3.4s');
    });

    test('la reconversión con ffmpeg se anuncia como tal', () {
      const progress = BufferProgress(
        phase: BufferPhase.converting,
        waited: Duration(milliseconds: 6100),
      );

      expect(progress.describe(), 'Reconvirtiendo con ffmpeg… 6.1s');
    });

    test('el relleno del búfer se refiere al objetivo de directo', () {
      const half = BufferProgress(
        phase: BufferPhase.buffering,
        waited: Duration(seconds: 1),
        bufferedSeconds: 5,
      );
      const full = BufferProgress(
        phase: BufferPhase.buffering,
        waited: Duration(seconds: 1),
        bufferedSeconds: 25,
      );

      expect(half.fill, closeTo(0.5, 0.001));
      expect(full.fill, 1.0, reason: 'la barra no puede pasarse del objetivo');
      expect(half.describe(), '50% · 5.0s en búfer');
    });

    test('la velocidad se presenta en unidades legibles', () {
      const progress = BufferProgress(
        phase: BufferPhase.buffering,
        waited: Duration(seconds: 2),
        bufferedSeconds: 4,
        speedBytesPerSecond: 1943907,
      );

      expect(progress.describe(), '40% · 4.0s en búfer · 1.9 MB/s');
    });

    test('con búfer pero sin relleno medible no muestra un 0% falso', () {
      const progress = BufferProgress(
        phase: BufferPhase.buffering,
        waited: Duration(seconds: 1),
        speedBytesPerSecond: 2048,
      );

      expect(progress.describe(), '2 KB/s');
    });
  });

  group('BufferProgressProbe', () {
    test('publica el búfer y la velocidad que da mpv', () async {
      final mpv = _FakeMpv({
        'time-pos': '1.5',
        'demuxer-cache-duration': '4.48',
        'cache-speed': '8857',
      });
      final probe = BufferProgressProbe(
        readProperty: mpv.read,
        interval: const Duration(milliseconds: 20),
      );
      addTearDown(probe.dispose);

      final progress = await (() {
        probe.begin();
        return probe.stream.first;
      })();

      expect(progress.phase, BufferPhase.buffering);
      expect(progress.bufferedSeconds, 4.48);
      expect(progress.speedBytesPerSecond, 8857);
      expect(mpv.asked, contains('demuxer-cache-duration'));
    });

    test('sin imagen todavía, la fase es la de conexión', () async {
      final mpv = _FakeMpv({'time-pos': '0', 'demuxer-cache-duration': ''});
      final probe = BufferProgressProbe(
        readProperty: mpv.read,
        interval: const Duration(milliseconds: 20),
      );
      addTearDown(probe.dispose);

      final progress = await (() {
        probe.begin();
        return probe.stream.first;
      })();

      expect(progress.phase, BufferPhase.connecting);
      expect(progress.bufferedSeconds, isNull);
    });

    test('el paso al proxy de ffmpeg cambia la fase que se anuncia', () async {
      final mpv = _FakeMpv({'time-pos': '0'});
      final probe = BufferProgressProbe(
        readProperty: mpv.read,
        interval: const Duration(milliseconds: 20),
      );
      addTearDown(probe.dispose);

      probe.begin();
      await probe.stream.first;
      probe.markConverting();

      final progress = await probe.stream.first;
      expect(progress.phase, BufferPhase.converting);
    });

    test('una vez hay imagen, la fase deja de ser la de arranque', () async {
      final mpv = _FakeMpv({'time-pos': '0'});
      final probe = BufferProgressProbe(
        readProperty: mpv.read,
        interval: const Duration(milliseconds: 20),
      );
      addTearDown(probe.dispose);

      probe.begin(converting: true);
      await probe.stream.first;

      mpv.values['time-pos'] = '2.0';
      final progress = await probe.stream.first;
      expect(progress.phase, BufferPhase.buffering);
    });

    test('stop cancela el sondeo y no quedan temporizadores', () async {
      final mpv = _FakeMpv({'time-pos': '1'});
      final probe = BufferProgressProbe(
        readProperty: mpv.read,
        interval: const Duration(milliseconds: 20),
      );
      addTearDown(probe.dispose);

      probe.begin();
      await probe.stream.first;
      expect(probe.isRunning, isTrue);

      probe.stop();
      expect(probe.isRunning, isFalse);
    });
  });
}
