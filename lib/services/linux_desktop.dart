import 'dart:io';

/// Desktop environment helpers for choosing a capture backend.
class LinuxDesktop {
  LinuxDesktop._();

  static String get currentDesktop {
    return (Platform.environment['XDG_CURRENT_DESKTOP'] ??
            Platform.environment['DESKTOP_SESSION'] ??
            '')
        .toUpperCase();
  }

  static bool get isGnome =>
      currentDesktop.contains('GNOME') || currentDesktop.contains('UNITY');

  static bool get isKde =>
      currentDesktop.contains('KDE') || currentDesktop.contains('PLASMA');

  static bool get isWlroots {
    return currentDesktop.contains('SWAY') ||
        currentDesktop.contains('HYPR') ||
        currentDesktop.contains('RIVER') ||
        currentDesktop.contains('WAYFIRE') ||
        currentDesktop.contains('WLROOTS') ||
        currentDesktop.contains('LABWC');
  }
}

/// Software VP8 encode path for `org.gnome.Shell.Screencast`.
///
/// GNOME 46 tries DMABuf+OpenH264, then DMABuf+GL+VP8. Ubuntu often lacks
/// `openh264enc` / `h264parse`, so the service settles on the GL pipeline,
/// which can report PLAYING without ever writing a file. Forcing memfd +
/// `videoconvert` + `vp8enc` matches GNOME's own last-resort pipeline.
/// `%T` is replaced by gnome-shell with a thread count.
const gnomeSoftwareWebmPipeline =
    'videoconvert chroma-mode=none dither=none matrix-mode=output-only n-threads=%T ! '
    'queue ! '
    'vp8enc cpu-used=16 max-quantizer=17 deadline=1 keyframe-mode=disabled '
    'threads=%T static-threshold=1000 buffer-size=20000 ! '
    'queue ! '
    'webmmux';

/// Same video path as [gnomeSoftwareWebmPipeline], plus default Pulse/PipeWire
/// source (microphone) muxed as Opus. GNOME prepends the video source before
/// this string, so the named `mux.` pads are valid parse-launch syntax.
const gnomeSoftwareWebmMicPipeline =
    'videoconvert chroma-mode=none dither=none matrix-mode=output-only n-threads=%T ! '
    'queue ! '
    'vp8enc cpu-used=16 max-quantizer=17 deadline=1 keyframe-mode=disabled '
    'threads=%T static-threshold=1000 buffer-size=20000 ! '
    'queue ! mux. '
    'pulsesrc provide-clock=false ! queue ! audioconvert ! audioresample ! '
    'opusenc bitrate=128000 ! queue ! mux. '
    'webmmux name=mux';

String gnomeScreencastPipeline({required bool recordMicrophone}) {
  return recordMicrophone
      ? gnomeSoftwareWebmMicPipeline
      : gnomeSoftwareWebmPipeline;
}

/// GNOME 46+ treats the D-Bus path as a stem and appends `.mp4` / `.webm`.
/// Passing `.mp4` becomes `file.mp4.mp4`; `.webm` is stripped as a compat hack.
String gnomeScreencastPathStem(String path) {
  final lower = path.toLowerCase();
  for (final ext in const ['.webm', '.mp4', '.mkv']) {
    if (lower.endsWith(ext)) {
      return path.substring(0, path.length - ext.length);
    }
  }
  return path;
}

List<String> buildGnomeScreencastAreaArgs({
  required int x,
  required int y,
  required int width,
  required int height,
  required String outputPath,
  int fps = 30,
  bool recordMicrophone = false,
}) {
  final pipeline = gnomeScreencastPipeline(recordMicrophone: recordMicrophone);
  return [
    'call',
    '--session',
    '--dest',
    'org.gnome.Shell.Screencast',
    '--object-path',
    '/org/gnome/Shell/Screencast',
    '--method',
    'org.gnome.Shell.Screencast.ScreencastArea',
    '$x',
    '$y',
    '$width',
    '$height',
    gnomeScreencastPathStem(outputPath),
    "{'framerate': <$fps>, 'draw-cursor': <true>, 'pipeline': <'$pipeline'>}",
  ];
}

List<String> buildGnomeStopScreencastArgs() {
  return const [
    'call',
    '--session',
    '--dest',
    'org.gnome.Shell.Screencast',
    '--object-path',
    '/org/gnome/Shell/Screencast',
    '--method',
    'org.gnome.Shell.Screencast.StopScreencast',
  ];
}

List<String> buildGnomeScreenshotArgs(String outputPath) {
  return [
    'call',
    '--session',
    '--dest',
    'org.gnome.Shell.Screenshot',
    '--object-path',
    '/org/gnome/Shell/Screenshot',
    '--method',
    'org.gnome.Shell.Screenshot.Screenshot',
    'true',
    'false',
    outputPath,
  ];
}

List<String> buildGnomeScreenshotAreaArgs({
  required int x,
  required int y,
  required int width,
  required int height,
  required String outputPath,
}) {
  return [
    'call',
    '--session',
    '--dest',
    'org.gnome.Shell.Screenshot',
    '--object-path',
    '/org/gnome/Shell/Screenshot',
    '--method',
    'org.gnome.Shell.Screenshot.ScreenshotArea',
    '$x',
    '$y',
    '$width',
    '$height',
    'false',
    outputPath,
  ];
}

/// Parses `gdbus call` stdout such as `(true, '/tmp/out.webm')`.
String? parseGdbusSuccessPath(String stdout) {
  final match = RegExp(r"\(true,\s*'([^']*)'\)").firstMatch(stdout.trim());
  var path = match?.group(1);
  if (path == null || path.isEmpty) {
    return null;
  }
  if (path.startsWith('file://')) {
    path = Uri.parse(path).toFilePath();
  }
  return path;
}

bool parseGdbusBoolean(String stdout) {
  return stdout.trim().startsWith('(true');
}

/// Portal Request object path for a caller unique name and handle token.
///
/// Unique names look like `:1.42`. The portal replaces `:` and `.` so the
/// path becomes `/org/freedesktop/portal/desktop/request/1_42/TOKEN`.
String portalRequestObjectPath({
  required String uniqueName,
  required String handleToken,
}) {
  var sender = uniqueName;
  if (sender.startsWith(':')) {
    sender = sender.substring(1);
  }
  return '/org/freedesktop/portal/desktop/request/'
      '${sender.replaceAll('.', '_')}/$handleToken';
}

/// Converts a portal `file://` URI (or a plain path) to a filesystem path.
String? filePathFromPortalUri(String? uri) {
  if (uri == null || uri.isEmpty) {
    return null;
  }
  if (uri.startsWith('/') && !uri.startsWith('//')) {
    return uri;
  }
  final parsed = Uri.tryParse(uri);
  if (parsed == null) {
    return null;
  }
  if (parsed.scheme == 'file') {
    return parsed.toFilePath();
  }
  return null;
}
