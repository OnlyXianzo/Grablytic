import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Fires once, the first time any transport actually starts the engine.
///
/// Two things on Home depend on the engine having been started, and must
/// not start it themselves (#91):
///
///  * the resume scan (`scan_resume_candidates`), which is the whole point
///    of the "interrupted downloads" card, and
///  * the engine status banner, whose live read runs `bootstrap()`.
///
/// Both used to run on the first frame — the banner through
/// `engineStatusProvider`, the scan through `ResumeNotifier`'s constructor
/// (and `downloadProvider` reads that notifier, so it fired even with the
/// card removed). That put `Python.start` → `import yt_dlp` → 40.5 MiB back
/// on every returning launch, one frame later than pass 3 removed it.
///
/// Now the transports report the start and the UI reacts to it. Nothing on
/// Home can start the engine; things on Home can wake up once something
/// else did.
final StreamController<void> _started =
    StreamController<void>.broadcast(sync: false);

bool _hasStarted = false;

/// True once the engine has been started in this process.
bool get engineHasStarted => _hasStarted;

/// Emits when the engine starts. Late subscribers get an immediate event if
/// it already started, so a widget built afterwards is not left waiting.
Stream<void> get engineStarted =>
    _hasStarted ? Stream<void>.value(null) : _started.stream;

/// [engineStarted] as a provider, for widgets that want to rebuild on it.
final engineStartedProvider = StreamProvider<void>((ref) => engineStarted);

/// Called by a transport when the engine is genuinely up.
///
/// Idempotent: the first report wins and later ones are ignored, because
/// every consumer here wants "has it started", not "how many times".
///
/// Not `@visibleForTesting`: the callers are the transports, which live
/// outside this library. (`resetEngineStartSignal` is the test-only one.)
void markEngineStarted() {
  if (_hasStarted) return;
  _hasStarted = true;
  _started.add(null);
}

/// Test hook: forget that the engine ever started.
@visibleForTesting
void resetEngineStartSignal() {
  _hasStarted = false;
}
