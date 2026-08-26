import 'package:flutter/material.dart';

import '../controllers/recording_controller.dart';
import '../widgets/recording_controls.dart';

class RecordingScreen extends StatelessWidget {
  const RecordingScreen({
    super.key,
    required this.controller,
    required this.onPauseResume,
    required this.onStop,
  });

  final RecordingController controller;
  final VoidCallback onPauseResume;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121418),
      body: Align(
        alignment: Alignment.topLeft,
        child: RecordingControls(
          controller: controller,
          onPauseResume: onPauseResume,
          onStop: onStop,
        ),
      ),
    );
  }
}
