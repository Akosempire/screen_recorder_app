import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../screens/upgrade_dialog.dart';
import '../services/app_update.dart';
import '../services/pro_service.dart';
import '../ui/studio_theme.dart';
import 'android_recorder.dart';

/// Screen Recorder for Android phones and tablets.
class MobileApp extends StatelessWidget {
  const MobileApp({super.key, this.recorder});

  final AndroidRecorder? recorder;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Screen Recorder',
      debugShowCheckedModeBanner: false,
      theme: Studio.theme(ThemeData(useMaterial3: true, colorSchemeSeed: Studio.primary)),
      home: MobileHome(recorder: recorder),
    );
  }
}

class MobileHome extends StatefulWidget {
  const MobileHome({super.key, this.recorder});

  final AndroidRecorder? recorder;

  @override
  State<MobileHome> createState() => _MobileHomeState();
}

class _MobileHomeState extends State<MobileHome> with WidgetsBindingObserver {
  late final AndroidRecorder _rec = widget.recorder ?? AndroidRecorder();
  final _pro = ProService.instance;
  bool _mic = true;
  bool _wasBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rec.addListener(_onRecorder);
    _boot();
  }

  Future<void> _boot() async {
    try {
      final dir = await _rec.filesDir();
      if (dir != null) _pro.storeOverride = File('$dir/pro.json');
    } catch (_) {}
    if (appBuild > 0) {
      unawaited(_pro.start());
      AppUpdateService.instance.start();
    }
    await _rec.sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rec.removeListener(_onRecorder);
    if (widget.recorder == null) _rec.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _rec.sync();
      if (appBuild > 0) _pro.refresh();
    }
  }

  void _onRecorder() {
    final message = _rec.takeMessage();
    if (message != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
    // A recording just finished.
    if (_wasBusy && !_rec.busy && mounted) {
      if (_rec.lastStoppedAtLimit && !_pro.isPro) {
        _pro.stoppedAtLimit = true;
        showUpgradeDialog(context);
      } else if (_rec.recordings.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to your Gallery: Movies › Screen Recorder')),
        );
      }
    }
    _wasBusy = _rec.busy;
  }

  Future<void> _start() async {
    final limit = _pro.recordingLimit;
    await _rec.start(mic: _mic, maxSeconds: limit?.inSeconds);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_rec, _pro, AppUpdateService.instance]),
      builder: (context, _) => Scaffold(
        backgroundColor: Studio.chrome,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: RefreshIndicator(
                onRefresh: _rec.refresh,
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(child: _header()),
                    SliverToBoxAdapter(child: _recordCard()),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
                        child: Text('Your recordings', style: StudioText.title.copyWith(fontSize: 18)),
                      ),
                    ),
                    if (_rec.recordings.isEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(20, 4, 20, 32),
                          child: Text(
                            'Recordings you make appear here and in your Gallery (Movies › Screen Recorder).',
                            style: StudioText.body,
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                        sliver: SliverGrid(
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 360,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 1.25,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, i) => _RecordingTile(rec: _rec, item: _rec.recordings[i]),
                            childCount: _rec.recordings.length,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 32,
              height: 32,
              color: const Color(0xFF15181F),
              child: const Icon(Icons.fiber_manual_record, color: Studio.record, size: 18),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(child: Text('Screen Recorder', style: StudioText.title)),
          if (AppUpdateService.instance.updateAvailable)
            IconButton(
              tooltip: 'A new version is ready: download it',
              onPressed: AppUpdateService.instance.install,
              icon: const Icon(Icons.system_update_alt, color: Studio.ok),
            ),
          if (_pro.isPro)
            TextButton.icon(
              onPressed: () => showUpgradeDialog(context),
              icon: const Icon(Icons.workspace_premium_outlined, size: 18),
              label: const Text('Pro'),
            )
          else if (_pro.paymentsEnabled)
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Studio.highlight, foregroundColor: Studio.ink),
              onPressed: () => showUpgradeDialog(context),
              icon: const Icon(Icons.bolt, size: 18),
              label: Text(_pro.waitingForPayment ? 'Finishing…' : 'Upgrade'),
            ),
        ],
      ),
    );
  }

  Widget _recordCard() {
    final state = _rec.state;
    final limit = _pro.recordingLimit;
    final recording = state == PhoneRecorderState.recording || state == PhoneRecorderState.paused;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      decoration: BoxDecoration(
        color: Studio.surface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: Studio.raised,
      ),
      child: Column(
        children: [
          if (!recording) ...[
            _RecordButton(
              busy: state == PhoneRecorderState.starting,
              onPressed: state == PhoneRecorderState.idle ? _start : null,
            ),
            const SizedBox(height: 14),
            const Text('Tap to record your screen', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text(
              'Then switch to any app. Stop from the notification or come back here.',
              textAlign: TextAlign.center,
              style: StudioText.body,
            ),
            const SizedBox(height: 14),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _mic,
              onChanged: (v) => setState(() => _mic = v),
              title: const Text('Record sound from the microphone'),
              secondary: Icon(_mic ? Icons.mic : Icons.mic_off_outlined),
            ),
          ] else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.fiber_manual_record,
                    color: state == PhoneRecorderState.paused ? Studio.faint : Studio.record, size: 16),
                const SizedBox(width: 8),
                Text(state == PhoneRecorderState.paused ? 'Paused' : 'Recording',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            Text(_fmt(_rec.elapsed),
                style: const TextStyle(
                    fontSize: 48, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
            if (limit != null)
              Text('Free recordings stop at ${_fmt(limit)}',
                  style: StudioText.caption.copyWith(color: const Color(0xFF8A6100))),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: state == PhoneRecorderState.paused ? _rec.resume : _rec.pause,
                    icon: Icon(state == PhoneRecorderState.paused ? Icons.play_arrow : Icons.pause),
                    label: Text(state == PhoneRecorderState.paused ? 'Resume' : 'Pause'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Studio.record),
                    onPressed: _rec.stop,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                ),
              ],
            ),
          ],
          if (!recording && limit != null) ...[
            const Divider(height: 24),
            Row(
              children: [
                const Icon(Icons.timer_outlined, size: 18, color: Studio.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Free: up to ${limit.inMinutes} minutes per recording.', style: StudioText.body),
                ),
                TextButton(onPressed: () => showUpgradeDialog(context), child: const Text('Go Pro')),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.onPressed, required this.busy});

  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('record'),
      button: true,
      label: 'Start recording',
      child: Material(
        color: Studio.record,
        shape: const CircleBorder(),
        elevation: 6,
        shadowColor: Studio.record.withValues(alpha: 0.4),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 104,
            height: 104,
            child: Center(
              child: busy
                  ? const SizedBox(
                      width: 30, height: 30, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                  : Container(
                      width: 34,
                      height: 34,
                      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecordingTile extends StatelessWidget {
  const _RecordingTile({required this.rec, required this.item});

  final AndroidRecorder rec;
  final PhoneRecording item;

  @override
  Widget build(BuildContext context) {
    final mb = item.size / (1024 * 1024);
    return Material(
      color: Studio.surface,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => rec.open(item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FutureBuilder<Uint8List?>(
                    future: rec.thumbnail(item.uri),
                    builder: (context, snap) => snap.data == null
                        ? Container(color: Studio.well)
                        : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(6)),
                      child: Text(_fmt(item.duration),
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const Center(child: Icon(Icons.play_circle_fill, color: Color(0xE6FFFFFF), size: 44)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.name.replaceAll('.mp4', ''),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text('${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB', style: StudioText.caption),
                      ],
                    ),
                  ),
                  IconButton(tooltip: 'Share', icon: const Icon(Icons.share_outlined), onPressed: () => rec.share(item)),
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('Delete this recording?'),
                          content: const Text('It will be removed from your Gallery too.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                          ],
                        ),
                      );
                      if (ok == true) await rec.delete(item);
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
