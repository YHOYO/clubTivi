/// Decisión de reanudar: si un título reabierto empieza por donde se dejó y si
/// lo guardado cuenta como terminado.
///
/// Vive aparte del reproductor y de la base para poder probarla sin motor ni
/// pantalla: son cuatro umbrales y dos casos raros (duración desconocida y
/// fichero distinto).
library;

/// Antes de este punto no merece la pena reanudar: treinta segundos de créditos
/// o de zapping y el usuario prefiere empezar de cero.
const minResumePosition = Duration(seconds: 30);

/// A partir de aquí se considera visto. Guardar el 95 % como «empezar en 42:45»
/// deja al usuario viendo los títulos de crédito cada vez que reabre.
const completedRatio = 0.95;

/// Cuánto puede bailar la duración entre contenedores sin que sea otro fichero.
/// Un montaje distinto cambia minutos, no segundos de redondeo.
const durationTolerance = Duration(seconds: 2);

/// Qué hacer al reabrir.
class ResumePoint {
  /// Dónde empezar; [Duration.zero] significa «desde el principio».
  final Duration position;

  /// El progreso guardado ya está al final: no hay nada que reanudar, pero la
  /// fila debe quedar como vista.
  final bool completed;

  const ResumePoint._(this.position, this.completed);

  static const none = ResumePoint._(Duration.zero, false);
  static const finished = ResumePoint._(Duration.zero, true);

  bool get shouldResume => position > Duration.zero;

  @override
  String toString() =>
      'ResumePoint(${position.inSeconds}s, completed: $completed)';
}

/// Decide si reanudar con lo guardado.
///
/// [position] y [duration] son lo que quedó grabado del capítulo;
/// [currentDuration] es lo que mide el fichero que se acaba de abrir. Si difiere
/// de la duración guardada el enlace es otro montaje (u otro capítulo del pack)
/// y el tiempo guardado no señala nada: se empieza de cero.
ResumePoint resumePoint(
  Duration position,
  Duration duration, {
  Duration? currentDuration,
}) {
  // Sin duración no hay porcentaje: mejor empezar de cero que adivinar.
  if (duration <= Duration.zero) return ResumePoint.none;
  if (position <= Duration.zero) return ResumePoint.none;

  if (currentDuration != null &&
      currentDuration > Duration.zero &&
      (currentDuration - duration).abs() > durationTolerance) {
    return ResumePoint.none;
  }

  if (position >= duration * completedRatio) return ResumePoint.finished;
  if (position < minResumePosition) return ResumePoint.none;
  return ResumePoint._(position, false);
}
