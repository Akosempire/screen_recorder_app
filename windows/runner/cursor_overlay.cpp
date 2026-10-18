#include "cursor_overlay.h"

#include <algorithm>
#include <cmath>

namespace {

constexpr wchar_t kOverlayClassName[] = L"ScreenRecorderCursorOverlay";
constexpr UINT_PTR kTimerId = 1;
constexpr UINT kTimerIntervalMs = 15;

// Geometry in logical (96 DPI) pixels; scaled by the monitor DPI.
constexpr double kHaloRadius = 22.0;
constexpr double kRingWidth = 2.5;
constexpr double kRippleMaxRadius = 54.0;
constexpr double kRippleWidth = 3.0;
constexpr ULONGLONG kRippleDurationMs = 450;

struct Rgb {
  double r;
  double g;
  double b;
};

constexpr Rgb kYellow = {255.0, 214.0, 0.0};
constexpr Rgb kBlue = {66.0, 165.0, 245.0};

double Clamp01(double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); }

// Premultiplied source-over accumulation.
struct Pixel {
  double r = 0, g = 0, b = 0, a = 0;

  void Over(const Rgb& c, double alpha) {
    if (alpha <= 0.0) return;
    const double inv = 1.0 - alpha;
    r = c.r * alpha + r * inv;
    g = c.g * alpha + g * inv;
    b = c.b * alpha + b * inv;
    a = alpha + a * inv;
  }
};

bool g_class_registered = false;

}  // namespace

CursorOverlay::CursorOverlay() = default;

CursorOverlay::~CursorOverlay() {
  Hide();
  ReleaseSurface();
  if (hwnd_) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
}

bool CursorOverlay::EnsureWindow() {
  if (hwnd_) return true;
  HINSTANCE instance = GetModuleHandle(nullptr);
  if (!g_class_registered) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = CursorOverlay::WndProc;
    wc.hInstance = instance;
    wc.hCursor = nullptr;
    wc.lpszClassName = kOverlayClassName;
    if (!RegisterClassExW(&wc) &&
        GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      return false;
    }
    g_class_registered = true;
  }
  hwnd_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW |
          WS_EX_NOACTIVATE,
      kOverlayClassName, L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
      instance, this);
  return hwnd_ != nullptr;
}

bool CursorOverlay::EnsureSurface(int size) {
  if (bits_ && size == size_) return true;
  ReleaseSurface();
  HDC screen = GetDC(nullptr);
  mem_dc_ = CreateCompatibleDC(screen);
  ReleaseDC(nullptr, screen);
  if (!mem_dc_) return false;

  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = size;
  bmi.bmiHeader.biHeight = -size;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  bitmap_ = CreateDIBSection(mem_dc_, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!bitmap_ || !bits) {
    ReleaseSurface();
    return false;
  }
  bits_ = static_cast<uint32_t*>(bits);
  old_bitmap_ = SelectObject(mem_dc_, bitmap_);
  size_ = size;
  dirty_ = true;
  return true;
}

void CursorOverlay::ReleaseSurface() {
  if (mem_dc_) {
    if (old_bitmap_) SelectObject(mem_dc_, old_bitmap_);
    DeleteDC(mem_dc_);
  }
  if (bitmap_) DeleteObject(bitmap_);
  mem_dc_ = nullptr;
  bitmap_ = nullptr;
  old_bitmap_ = nullptr;
  bits_ = nullptr;
  size_ = 0;
}

bool CursorOverlay::Show(bool halo, bool ripples) {
  draw_halo_ = halo;
  draw_ripples_ = ripples;
  dirty_ = true;
  if (visible_) return true;
  if (!EnsureWindow()) return false;
  ripples_.clear();
  left_was_down_ = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;
  right_was_down_ = (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0;
  last_cursor_ = {LONG_MIN, LONG_MIN};
  dirty_ = true;
  visible_ = true;
  Tick();
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  SetTimer(hwnd_, kTimerId, kTimerIntervalMs, nullptr);
  return true;
}

void CursorOverlay::Hide() {
  if (!visible_) return;
  visible_ = false;
  if (hwnd_) {
    KillTimer(hwnd_, kTimerId);
    ShowWindow(hwnd_, SW_HIDE);
  }
  ripples_.clear();
}

void CursorOverlay::Tick() {
  if (!visible_ || !hwnd_) return;

  POINT cursor;
  if (!GetCursorPos(&cursor)) return;

  // Per-monitor DPI of where the overlay currently is.
  UINT dpi = GetDpiForWindow(hwnd_);
  if (dpi == 0) dpi = 96;
  const double scale = dpi / 96.0;
  if (std::abs(scale - scale_) > 0.001) {
    scale_ = scale;
    dirty_ = true;
  }
  const int wanted =
      static_cast<int>(std::ceil((kRippleMaxRadius + kRippleWidth + 4) * 2 *
                                 scale_)) |
      1;
  if (!EnsureSurface(wanted)) return;

  const bool swapped = GetSystemMetrics(SM_SWAPBUTTON) != 0;
  const bool phys_left = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;
  const bool phys_right = (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0;
  const bool left = swapped ? phys_right : phys_left;
  const bool right = swapped ? phys_left : phys_right;

  const ULONGLONG now = GetTickCount64();
  if (draw_ripples_) {
    if (left && !left_was_down_) ripples_.push_back({now, false});
    if (right && !right_was_down_) ripples_.push_back({now, true});
  }
  left_was_down_ = left;
  right_was_down_ = right;

  ripples_.erase(std::remove_if(ripples_.begin(), ripples_.end(),
                                [now](const Ripple& r) {
                                  return now - r.start_ms > kRippleDurationMs;
                                }),
                 ripples_.end());

  const bool pressed = left || right;
  if (pressed != last_pressed_) dirty_ = true;
  last_pressed_ = pressed;
  if (!ripples_.empty()) dirty_ = true;

  const bool moved =
      cursor.x != last_cursor_.x || cursor.y != last_cursor_.y;
  if (dirty_) {
    Render(pressed, now);
  }
  if (dirty_ || moved) {
    Present(cursor);
    last_cursor_ = cursor;
  }
  dirty_ = !ripples_.empty();

  // Other always-on-top windows can cover us; re-assert once a second.
  if (now - last_topmost_ms_ > 1000) {
    last_topmost_ms_ = now;
    SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
}

void CursorOverlay::Render(bool pressed, ULONGLONG now) {
  const int n = size_;
  const double c = (n - 1) / 2.0;
  const double halo = kHaloRadius * scale_ * (pressed ? 0.85 : 1.0);
  const double ring_w = kRingWidth * scale_;
  const double fill_alpha = pressed ? 0.45 : 0.28;
  const double ring_alpha = pressed ? 0.95 : 0.8;

  struct ActiveRipple {
    double radius;
    double width;
    double alpha;
    const Rgb* color;
  };
  std::vector<ActiveRipple> active;
  for (const auto& r : ripples_) {
    const double p =
        Clamp01(static_cast<double>(now - r.start_ms) /
                static_cast<double>(kRippleDurationMs));
    const double eased = 1.0 - (1.0 - p) * (1.0 - p);
    active.push_back({(kHaloRadius + (kRippleMaxRadius - kHaloRadius) * eased) *
                          scale_,
                      kRippleWidth * scale_ * (1.0 - 0.5 * p),
                      0.9 * (1.0 - p), r.right ? &kBlue : &kYellow});
  }

  for (int y = 0; y < n; ++y) {
    const double dy = y - c;
    for (int x = 0; x < n; ++x) {
      const double dx = x - c;
      const double d = std::sqrt(dx * dx + dy * dy);
      Pixel px;
      if (draw_halo_) {
        // Soft filled halo.
        px.Over(kYellow, fill_alpha * Clamp01(halo - d + 0.5));
        // Crisp ring on the halo edge.
        px.Over(kYellow,
                ring_alpha * Clamp01(ring_w / 2 - std::abs(d - halo) + 0.5));
      }
      for (const auto& r : active) {
        px.Over(*r.color,
                r.alpha * Clamp01(r.width / 2 - std::abs(d - r.radius) + 0.5));
      }
      const auto a = static_cast<uint32_t>(std::lround(Clamp01(px.a) * 255));
      const auto rr = static_cast<uint32_t>(std::lround(std::min(px.r, 255.0)));
      const auto gg = static_cast<uint32_t>(std::lround(std::min(px.g, 255.0)));
      const auto bb = static_cast<uint32_t>(std::lround(std::min(px.b, 255.0)));
      // BGRA, premultiplied (px.r/g/b are already premultiplied).
      bits_[y * n + x] = (a << 24) | (rr << 16) | (gg << 8) | bb;
    }
  }
}

void CursorOverlay::Present(POINT cursor) {
  POINT dst = {cursor.x - size_ / 2, cursor.y - size_ / 2};
  SIZE size = {size_, size_};
  POINT src = {0, 0};
  BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  HDC screen = GetDC(nullptr);
  UpdateLayeredWindow(hwnd_, screen, &dst, &size, mem_dc_, &src, 0, &blend,
                      ULW_ALPHA);
  ReleaseDC(nullptr, screen);
}

LRESULT CALLBACK CursorOverlay::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                        LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return DefWindowProc(hwnd, message, wparam, lparam);
  }
  auto* self =
      reinterpret_cast<CursorOverlay*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  switch (message) {
    case WM_TIMER:
      if (self && wparam == kTimerId) self->Tick();
      return 0;
    case WM_DPICHANGED:
      // Size is managed by Tick(); ignore the suggested rect.
      if (self) self->dirty_ = true;
      return 0;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_NCHITTEST:
      return HTTRANSPARENT;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
