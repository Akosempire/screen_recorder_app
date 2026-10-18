#ifndef RUNNER_CAMERA_BUBBLE_H_
#define RUNNER_CAMERA_BUBBLE_H_

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct IMFSourceReader;
struct IMFMediaSource;

// Floating webcam "face bubble": a draggable, always-on-top layered window
// that shows the camera feed in a circle (or rounded square), mirrored like
// a selfie. Because it is a normal on-screen window, FFmpeg gdigrab records
// it as part of the screen wherever the user drags it.
class CameraBubble {
 public:
  CameraBubble();
  ~CameraBubble();

  CameraBubble(const CameraBubble&) = delete;
  CameraBubble& operator=(const CameraBubble&) = delete;

  // Opens the camera and shows the bubble. Returns an empty string on
  // success, otherwise a user-facing error message. Calling it again while
  // visible updates size/shape (and reopens if the device changed).
  std::string Show(int diameter_logical, bool circle,
                   const std::wstring& device, HWND anchor);
  void Hide();
  bool visible() const { return visible_; }

  // Friendly names of the video capture devices.
  static std::vector<std::wstring> ListDevices();

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam);

  bool EnsureWindow();
  std::string OpenCamera(const std::wstring& device);
  void CloseCamera();
  void CaptureLoop();
  void Render();
  bool EnsureSurface(int size);
  void ReleaseSurface();

  HWND hwnd_ = nullptr;
  HDC mem_dc_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  HGDIOBJ old_bitmap_ = nullptr;
  uint32_t* bits_ = nullptr;
  int size_ = 0;

  int diameter_logical_ = 220;
  bool circle_ = true;
  bool visible_ = false;
  bool positioned_ = false;
  std::wstring device_;

  IMFSourceReader* reader_ = nullptr;
  IMFMediaSource* source_ = nullptr;
  std::thread thread_;
  std::atomic<bool> running_{false};

  std::mutex frame_mutex_;
  std::vector<uint32_t> frame_;
  int frame_width_ = 0;
  int frame_height_ = 0;
  bool has_frame_ = false;
};

#endif  // RUNNER_CAMERA_BUBBLE_H_
