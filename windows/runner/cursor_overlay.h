#ifndef RUNNER_CURSOR_OVERLAY_H_
#define RUNNER_CURSOR_OVERLAY_H_

#include <windows.h>

#include <climits>
#include <cstdint>
#include <vector>

// Click-through, always-on-top layered window that follows the mouse and
// draws a soft halo around the cursor plus an expanding ripple on every
// click (yellow = left, blue = right).
//
// Because it is a real on-screen window, it is visible live while recording
// and FFmpeg gdigrab (BitBlt with CAPTUREBLT) captures it into the video.
class CursorOverlay {
 public:
  CursorOverlay();
  ~CursorOverlay();

  CursorOverlay(const CursorOverlay&) = delete;
  CursorOverlay& operator=(const CursorOverlay&) = delete;

  bool Show();
  void Hide();
  bool visible() const { return visible_; }

 private:
  struct Ripple {
    ULONGLONG start_ms;
    bool right;
  };

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam);

  bool EnsureWindow();
  bool EnsureSurface(int size);
  void ReleaseSurface();
  void Tick();
  void Render(bool pressed, ULONGLONG now);
  void Present(POINT cursor);

  HWND hwnd_ = nullptr;
  HDC mem_dc_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  HGDIOBJ old_bitmap_ = nullptr;
  uint32_t* bits_ = nullptr;
  int size_ = 0;
  double scale_ = 1.0;
  bool visible_ = false;
  bool left_was_down_ = false;
  bool right_was_down_ = false;
  bool last_pressed_ = false;
  bool dirty_ = true;
  POINT last_cursor_ = {LONG_MIN, LONG_MIN};
  ULONGLONG last_topmost_ms_ = 0;
  std::vector<Ripple> ripples_;
};

#endif  // RUNNER_CURSOR_OVERLAY_H_
