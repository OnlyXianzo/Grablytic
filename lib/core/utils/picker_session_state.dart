/// In-memory session state for FormatPickerScreen toggles (T03).
///
/// Retains user customizations across format picker visits within the
/// same application session without modifying persistent Settings.
class PickerSessionState {
  static final PickerSessionState instance = PickerSessionState._();
  PickerSessionState._();

  bool? embedSubtitles;
  bool? audioOnly;
  String? qualityCeiling;
  bool clipEnabled = false;
  String clipStart = '';
  String clipEnd = '';

  void reset() {
    embedSubtitles = null;
    audioOnly = null;
    qualityCeiling = null;
    clipEnabled = false;
    clipStart = '';
    clipEnd = '';
  }
}
