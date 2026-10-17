/// Version comparison for update checks.
///
/// Versions look like `0.4.0`, `1.0.0-rc1` or `0.4.0+5` (the last part is the
/// build number and is ignored here). The rules are the ones from semver:
///
///   * `1.0.0` is newer than `1.0.0-rc1` (a pre-release precedes its release).
///   * `1.0.0-rc2` is newer than `1.0.0-rc1`.
///   * Missing parts count as zero: `1.2` equals `1.2.0`.
///
/// Anything that cannot be parsed counts as zero, so a weird tag in the release
/// list never looks newer than what the app is running.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.preRelease = const <String>[],
  });

  final int major;
  final int minor;
  final int patch;

  /// Pre-release identifiers, split on `.`. Empty for a final release.
  final List<String> preRelease;

  bool get isPreRelease => preRelease.isNotEmpty;

  static final RegExp _numeric = RegExp(r'^\d+$');

  /// Parses `v1.2.3-rc1+build`; anything unparsable becomes `0.0.0`.
  factory AppVersion.parse(String raw) {
    var text = raw.trim();
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1);
    }

    // The build number (`+5`) only matters to the stores, never to ordering.
    final plus = text.indexOf('+');
    if (plus >= 0) {
      text = text.substring(0, plus);
    }

    var pre = <String>[];
    final dash = text.indexOf('-');
    if (dash >= 0) {
      pre = text
          .substring(dash + 1)
          .split('.')
          .where((part) => part.isNotEmpty)
          .toList(growable: false);
      text = text.substring(0, dash);
    }

    final parts = text.split('.');

    int at(int index) {
      if (index >= parts.length) return 0;
      final value = int.tryParse(parts[index].trim());
      return value ?? 0;
    }

    return AppVersion(
      major: at(0),
      minor: at(1),
      patch: at(2),
      preRelease: pre,
    );
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);

    // A final release wins over its pre-releases.
    if (preRelease.isEmpty && other.preRelease.isEmpty) return 0;
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;

    final length = preRelease.length < other.preRelease.length
        ? preRelease.length
        : other.preRelease.length;
    for (var i = 0; i < length; i++) {
      final left = preRelease[i];
      final right = other.preRelease[i];
      if (left == right) continue;

      final leftIsNumber = _numeric.hasMatch(left);
      final rightIsNumber = _numeric.hasMatch(right);
      if (leftIsNumber && rightIsNumber) {
        return int.parse(left).compareTo(int.parse(right));
      }
      // Numeric identifiers rank below alphanumeric ones.
      if (leftIsNumber) return -1;
      if (rightIsNumber) return 1;
      return left.compareTo(right);
    }

    // Fewer identifiers means the shorter one is the earlier pre-release.
    return preRelease.length.compareTo(other.preRelease.length);
  }

  /// `true` when this version is strictly newer than [other].
  bool isNewerThan(String other) => compareTo(AppVersion.parse(other)) > 0;

  @override
  String toString() {
    final core = '$major.$minor.$patch';
    return isPreRelease ? '$core-${preRelease.join('.')}' : core;
  }

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease.join('.'));
}

/// Compares two version strings. `>0` when [a] is newer than [b].
int compareAppVersions(String a, String b) =>
    AppVersion.parse(a).compareTo(AppVersion.parse(b));
