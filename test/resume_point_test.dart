// Los cuatro umbrales del plan: no reanudar si acaba de empezar, reanudar en el
// minuto 12, dar por visto al 95 % y desconfiar de una duración distinta.
import 'package:clubtivi/features/player/resume_point.dart';
import 'package:flutter_test/flutter_test.dart';

const _fortyFive = Duration(minutes: 45);

void main() {
  test('0:12 de 45:00 empieza de cero', () {
    final resume = resumePoint(const Duration(seconds: 12), _fortyFive);

    expect(resume.position, Duration.zero);
    expect(resume.shouldResume, isFalse);
    expect(resume.completed, isFalse);
  });

  test('12:00 de 45:00 reanuda en el minuto 12', () {
    final resume = resumePoint(const Duration(minutes: 12), _fortyFive);

    expect(resume.position, const Duration(minutes: 12));
    expect(resume.shouldResume, isTrue);
    expect(resume.completed, isFalse);
  });

  test('95 % cuenta como terminado y no reanuda', () {
    // 45 min × 0,95 = 42:45.
    final resume = resumePoint(const Duration(minutes: 42, seconds: 45), _fortyFive);

    expect(resume.completed, isTrue);
    expect(resume.position, Duration.zero);
    expect(resume.shouldResume, isFalse);
  });

  test('una duración distinta invalida el tiempo guardado', () {
    final resume = resumePoint(
      const Duration(minutes: 12),
      _fortyFive,
      currentDuration: const Duration(minutes: 47),
    );

    expect(resume.position, Duration.zero);
    expect(resume.shouldResume, isFalse);
    expect(resume.completed, isFalse);
  });

  test('un segundo de diferencia es el mismo fichero', () {
    final resume = resumePoint(
      const Duration(minutes: 12),
      _fortyFive,
      currentDuration: const Duration(minutes: 45, seconds: 1),
    );

    expect(resume.position, const Duration(minutes: 12));
  });

  test('la duración desconocida no reanuda', () {
    expect(
      resumePoint(const Duration(minutes: 12), Duration.zero).shouldResume,
      isFalse,
    );
  });

  test('el límite de 30 s es inclusivo', () {
    expect(
      resumePoint(const Duration(seconds: 29), _fortyFive).shouldResume,
      isFalse,
    );
    expect(
      resumePoint(const Duration(seconds: 30), _fortyFive).position,
      const Duration(seconds: 30),
    );
  });

  test('sin duración actual se confía en la guardada', () {
    final resume = resumePoint(
      const Duration(minutes: 12),
      _fortyFive,
      currentDuration: Duration.zero,
    );

    expect(resume.position, const Duration(minutes: 12));
  });

  test('un tiempo negativo no reanuda', () {
    expect(
      resumePoint(const Duration(seconds: -5), _fortyFive).shouldResume,
      isFalse,
    );
  });
}
