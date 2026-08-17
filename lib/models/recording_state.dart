/// Explicit recording lifecycle states.
enum RecordingState {
  idle,
  selectingRegion,
  ready,
  recording,
  paused,
  stopping,
  saving,
  completed,
  error,
}

extension RecordingStateX on RecordingState {
  String get label {
    switch (this) {
      case RecordingState.idle:
        return 'Ready';
      case RecordingState.selectingRegion:
        return 'Select a region';
      case RecordingState.ready:
        return 'Region selected';
      case RecordingState.recording:
        return 'Recording';
      case RecordingState.paused:
        return 'Paused';
      case RecordingState.stopping:
        return 'Stopping';
      case RecordingState.saving:
        return 'Saving';
      case RecordingState.completed:
        return 'Saved';
      case RecordingState.error:
        return 'Error';
    }
  }

  bool get canBeginSelection =>
      this == RecordingState.idle ||
      this == RecordingState.completed ||
      this == RecordingState.error ||
      this == RecordingState.ready;

  bool get canConfirmRegion =>
      this == RecordingState.selectingRegion || this == RecordingState.ready;

  bool get canCancelSelection =>
      this == RecordingState.selectingRegion || this == RecordingState.ready;

  bool get canStartRecording => this == RecordingState.ready;

  bool get canPause => this == RecordingState.recording;

  bool get canResume => this == RecordingState.paused;

  bool get canStop =>
      this == RecordingState.recording || this == RecordingState.paused;

  bool get isBusy =>
      this == RecordingState.stopping || this == RecordingState.saving;

  bool get isActiveCapture =>
      this == RecordingState.recording || this == RecordingState.paused;
}
