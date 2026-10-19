// `stop()` es el punto que sueltan las demás pantallas antes de abrir otro
// vídeo: debe dejar el servicio sin canal y avisar a la UI, sin crear un motor
// sólo para pararlo.
import 'package:clubtivi/features/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stop deja el servicio sin canal y lo anuncia', () async {
    final service = PlayerService();
    addTearDown(service.dispose);

    final announced = expectLater(service.currentUrlStream, emits(null));
    await service.stop();
    await announced;

    expect(service.currentUrl, isNull);
    expect(service.currentChannelId, isNull);

    // Llamarlo dos veces (tráiler y ficha, por ejemplo) no rompe nada.
    await service.stop();
    expect(service.currentUrl, isNull);
  });
}
