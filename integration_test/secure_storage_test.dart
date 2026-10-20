// El almacén seguro es una dependencia nativa: los tests de unidad usan
// dobles, así que aquí se comprueba contra el plugin real de la plataforma.
// En Windows usa el Administrador de credenciales; en Android, el Keystore.
//
//   flutter test integration_test/secure_storage_test.dart -d windows
import 'package:clubtivi/data/services/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('guarda, lee y borra un secreto de verdad', (tester) async {
    final store = SecureSecretStore();
    const key = 'integration.probe';

    await store.write(key, 'valor-secreto');
    expect(await store.read(key), 'valor-secreto');

    await store.write(key, 'otro-valor');
    expect(await store.read(key), 'otro-valor');

    await store.delete(key);
    expect(await store.read(key), isNull);
  });
}
