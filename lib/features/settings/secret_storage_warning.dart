import 'package:flutter/material.dart';

/// Aviso de que el almacén seguro no está disponible.
///
/// Sin él, la app seguiría funcionando con las credenciales en preferencias y
/// el usuario no sabría que no están cifradas. No borra nada: sólo lo dice.
class SecretStorageWarning extends StatelessWidget {
  const SecretStorageWarning({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('secret-storage-warning'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.orangeAccent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Colors.orangeAccent.withValues(alpha: 0.35),
          ),
        ),
        child: const Text(
          'Secure storage is unavailable on this device, so credentials stay '
          'in the app preferences until it works. Nothing was deleted.',
          style: TextStyle(
            color: Colors.orangeAccent,
            fontSize: 12,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
