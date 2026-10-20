/// Punto de entrada de los clientes debrid.
///
/// Cada proveedor vive en su propio fichero para poder leerlo —y cambiarlo—
/// sin cargar los demás. Esta biblioteca sólo los reexporta: el import
/// histórico `debrid_client.dart` sigue funcionando.
library;

export 'alldebrid_client.dart';
export 'debridlink_client.dart';
export 'offcloud_client.dart';
export 'premiumize_client.dart';
export 'putio_client.dart';
export 'realdebrid_client.dart';
