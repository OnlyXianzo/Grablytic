/// The build's version, stamped at compile time from `pubspec.yaml`.
///
/// `pubspec.yaml` is the only place the number is written. Before this, six
/// literals disagreed with each other — the build said `0.0.5+5`, the report
/// composer said `0.0.5+5` by hand, every crash draft said `0.0.1-beta+1`,
/// and the About screen said `0.0.1-beta` — so a crash issue, a screenshot
/// and the installed package could describe three different builds.
///
/// The value arrives through `--dart-define=GRABLYTIC_APP_VERSION`, the same
/// mechanism already used for the git SHA and Flutter version. `const` is
/// required: a non-const environment lookup is dropped by the AOT compiler.
class AppVersion {
  const AppVersion._();

  static const String _stamped = String.fromEnvironment(
    'GRABLYTIC_APP_VERSION',
  );

  /// `0.6.0+6` in a stamped build, `unknown` in a host that was built
  /// without the define (tests, and any local `flutter run`).
  static String get value => _stamped.isEmpty ? 'unknown' : _stamped;

  /// `0.6.0` — the version without the build number, for places that show a
  /// tag rather than a package version.
  static String get short => value.split('+').first;
}
