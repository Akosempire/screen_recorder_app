import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// A span of the recording, in seconds.
@immutable
class EditRange {
  const EditRange(this.start, this.end);

  final double start;
  final double end;

  double get length => end - start;

  @override
  bool operator ==(Object other) => other is EditRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'EditRange(${start.toStringAsFixed(2)}–${end.toStringAsFixed(2)})';
}

/// Simple edits made after recording: trim the start/end and cut sections
/// out of the middle. Export keeps [kept] and joins the pieces.
class RecordingEdit extends ChangeNotifier {
  RecordingEdit(double duration) : duration = math.max(0.0, duration), _trimEnd = math.max(0.0, duration);

  /// Length of the recording, in seconds.
  final double duration;

  /// Shortest piece we keep or cut (shorter ones are dropped).
  static const double minPiece = 0.2;

  /// Trim handles cannot get closer than this.
  static const double minKeep = 0.5;

  double _trimStart = 0;
  double _trimEnd;
  final List<EditRange> _cuts = [];
  double _playhead = 0;

  double get trimStart => _trimStart;
  double get trimEnd => _trimEnd;
  List<EditRange> get cuts => List.unmodifiable(_cuts);
  double get playhead => _playhead;

  bool get isEdited => _trimStart > 0.01 || _trimEnd < duration - 0.01 || _cuts.isNotEmpty;

  set playhead(double t) {
    final v = t.clamp(0.0, duration).toDouble();
    if (v == _playhead) return;
    _playhead = v;
    notifyListeners();
  }

  set trimStart(double t) {
    final v = t.clamp(0.0, math.max(0.0, _trimEnd - minKeep)).toDouble();
    if (v == _trimStart) return;
    _trimStart = v;
    notifyListeners();
  }

  set trimEnd(double t) {
    final v = t.clamp(math.min(duration, _trimStart + minKeep), duration).toDouble();
    if (v == _trimEnd) return;
    _trimEnd = v;
    notifyListeners();
  }

  /// Adds a cut around the playhead (2 s, or a tenth of the video if shorter).
  /// Returns its index, or -1 when there is no room.
  int addCutAtPlayhead() {
    final width = math.min(2.0, math.max(minPiece * 2, duration * 0.1));
    var start = (_playhead - width / 2).clamp(_trimStart, math.max(_trimStart, _trimEnd - width)).toDouble();
    var end = math.min(_trimEnd, start + width);
    if (end - start < minPiece) return -1;
    _cuts.add(EditRange(start, end));
    _cuts.sort((a, b) => a.start.compareTo(b.start));
    notifyListeners();
    return _cuts.indexWhere((c) => c.start == start && c.end == end);
  }

  /// Moves or resizes cut [index]; keeps it inside the video and at least
  /// [minPiece] long.
  void setCut(int index, double start, double end) {
    if (index < 0 || index >= _cuts.length) return;
    var s = start.clamp(0.0, duration).toDouble();
    var e = end.clamp(0.0, duration).toDouble();
    if (e - s < minPiece) {
      if (s + minPiece <= duration) {
        e = s + minPiece;
      } else {
        s = e - minPiece;
      }
    }
    final next = EditRange(s, e);
    if (_cuts[index] == next) return;
    _cuts[index] = next;
    notifyListeners();
  }

  void removeCut(int index) {
    if (index < 0 || index >= _cuts.length) return;
    _cuts.removeAt(index);
    notifyListeners();
  }

  void reset() {
    _trimStart = 0;
    _trimEnd = duration;
    _cuts.clear();
    notifyListeners();
  }

  /// The parts that will be exported, in order.
  List<EditRange> get kept => keptRanges(duration, _trimStart, _trimEnd, _cuts);

  double get keptDuration => kept.fold(0.0, (sum, r) => sum + r.length);

  /// Null when nothing is edited (export the whole file).
  List<EditRange>? get exportSegments => isEdited ? kept : null;
}

/// [trimStart]–[trimEnd] minus [cuts] (which may overlap or stick out),
/// dropping slivers shorter than [RecordingEdit.minPiece].
List<EditRange> keptRanges(double duration, double trimStart, double trimEnd, List<EditRange> cuts) {
  final lo = trimStart.clamp(0.0, duration).toDouble();
  final hi = trimEnd.clamp(lo, duration).toDouble();
  final sorted = [...cuts]..sort((a, b) => a.start.compareTo(b.start));
  final out = <EditRange>[];
  var cursor = lo;
  for (final c in sorted) {
    final s = c.start.clamp(lo, hi).toDouble();
    final e = c.end.clamp(lo, hi).toDouble();
    if (e <= cursor) continue;
    if (s > cursor && s - cursor >= RecordingEdit.minPiece) out.add(EditRange(cursor, s));
    cursor = math.max(cursor, e);
  }
  if (hi - cursor >= RecordingEdit.minPiece) out.add(EditRange(cursor, hi));
  return out;
}

/// Where playback should be at [t] so it only shows [kept] parts: [t] itself
/// inside a kept part, the start of the next kept part when [t] is in a cut,
/// or null once past the last kept part.
double? nextPlayableTime(List<EditRange> kept, double t) {
  for (final r in kept) {
    if (t < r.end - 0.03) return math.max(t, r.start);
  }
  return null;
}
