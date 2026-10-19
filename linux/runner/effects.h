#ifndef RUNNER_EFFECTS_H_
#define RUNNER_EFFECTS_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Live recording effects for Linux (X11): the yellow cursor halo with click
// ripples, and the draggable face-camera bubble. Both are real on-screen
// windows, so x11grab records them exactly as the user sees them.
//
// Uses the same method channel and methods as the Windows runner
// ("screen_recorder_app/windows"): showCursorOverlay, hideCursorOverlay,
// listCameras, showCamera, moveCamera, hideCamera.
void effects_register(FlBinaryMessenger* messenger);

#endif  // RUNNER_EFFECTS_H_
