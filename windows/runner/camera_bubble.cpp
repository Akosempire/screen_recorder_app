#include "camera_bubble.h"

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace {

constexpr wchar_t kBubbleClassName[] = L"ScreenRecorderCameraBubble";
constexpr UINT kFrameMessage = WM_APP + 41;
constexpr int kMargin = 4;  // room for the anti-aliased ring

bool g_class_registered = false;
bool g_mf_started = false;

template <typename T>
void SafeRelease(T** p) {
  if (p && *p) {
    (*p)->Release();
    *p = nullptr;
  }
}

double Clamp01(double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); }

std::wstring DeviceName(IMFActivate* activate) {
  WCHAR* name = nullptr;
  UINT32 length = 0;
  std::wstring result;
  if (SUCCEEDED(activate->GetAllocatedString(
          MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &length)) &&
      name) {
    result.assign(name, length);
    CoTaskMemFree(name);
  }
  return result;
}

// Coverage of a pixel centre (x, y) inside a w×h rounded rectangle with
// corner radius r, anti-aliased over ~1px.
double RoundedRectCoverage(double x, double y, double w, double h, double r) {
  const double cx = std::clamp(x, r, w - r);
  const double cy = std::clamp(y, r, h - r);
  const double dx = x - cx;
  const double dy = y - cy;
  const double d = std::sqrt(dx * dx + dy * dy);
  return Clamp01(r - d + 0.5);
}

}  // namespace

CameraBubble::CameraBubble() = default;

CameraBubble::~CameraBubble() {
  Hide();
  ReleaseSurface();
  if (hwnd_) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
  if (g_mf_started) {
    MFShutdown();
    g_mf_started = false;
  }
}

std::vector<std::wstring> CameraBubble::ListDevices() {
  std::vector<std::wstring> names;
  if (!g_mf_started) {
    if (FAILED(MFStartup(MF_VERSION))) return names;
    g_mf_started = true;
  }
  IMFAttributes* attributes = nullptr;
  if (FAILED(MFCreateAttributes(&attributes, 1))) return names;
  attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                      MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  IMFActivate** devices = nullptr;
  UINT32 count = 0;
  if (SUCCEEDED(MFEnumDeviceSources(attributes, &devices, &count))) {
    for (UINT32 i = 0; i < count; ++i) {
      names.push_back(DeviceName(devices[i]));
      devices[i]->Release();
    }
    CoTaskMemFree(devices);
  }
  SafeRelease(&attributes);
  return names;
}

bool CameraBubble::EnsureWindow() {
  if (hwnd_) return true;
  HINSTANCE instance = GetModuleHandle(nullptr);
  if (!g_class_registered) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = CameraBubble::WndProc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursor(nullptr, IDC_SIZEALL);
    wc.lpszClassName = kBubbleClassName;
    if (!RegisterClassExW(&wc) &&
        GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      return false;
    }
    g_class_registered = true;
  }
  hwnd_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kBubbleClassName, L"Camera", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
      instance, this);
  return hwnd_ != nullptr;
}

std::string CameraBubble::OpenCamera(const std::wstring& device) {
  if (!g_mf_started) {
    if (FAILED(MFStartup(MF_VERSION))) {
      return "Media Foundation is not available on this PC.";
    }
    g_mf_started = true;
  }

  IMFAttributes* attributes = nullptr;
  if (FAILED(MFCreateAttributes(&attributes, 1))) {
    return "Could not look for cameras.";
  }
  attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                      MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  IMFActivate** devices = nullptr;
  UINT32 count = 0;
  HRESULT hr = MFEnumDeviceSources(attributes, &devices, &count);
  SafeRelease(&attributes);
  if (FAILED(hr) || count == 0) {
    if (devices) CoTaskMemFree(devices);
    return "No camera was found. Plug one in and try again.";
  }

  UINT32 chosen = 0;
  if (!device.empty()) {
    for (UINT32 i = 0; i < count; ++i) {
      if (DeviceName(devices[i]) == device) {
        chosen = i;
        break;
      }
    }
  }
  hr = devices[chosen]->ActivateObject(IID_PPV_ARGS(&source_));
  for (UINT32 i = 0; i < count; ++i) devices[i]->Release();
  CoTaskMemFree(devices);
  if (FAILED(hr) || !source_) {
    if (hr == E_ACCESSDENIED) {
      return "Camera access is off. Turn on Settings > Privacy & security > "
             "Camera > Let desktop apps access your camera.";
    }
    return "The camera is busy or unavailable. Close other apps using it.";
  }

  IMFAttributes* reader_attributes = nullptr;
  MFCreateAttributes(&reader_attributes, 1);
  if (reader_attributes) {
    reader_attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING,
                                 TRUE);
  }
  hr = MFCreateSourceReaderFromMediaSource(source_, reader_attributes,
                                           &reader_);
  SafeRelease(&reader_attributes);
  if (FAILED(hr) || !reader_) {
    CloseCamera();
    return "Could not start the camera.";
  }

  IMFMediaType* type = nullptr;
  hr = MFCreateMediaType(&type);
  if (SUCCEEDED(hr)) {
    type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    hr = reader_->SetCurrentMediaType(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
        type);
  }
  SafeRelease(&type);
  if (FAILED(hr)) {
    CloseCamera();
    return "This camera's video format is not supported.";
  }
  device_ = device;
  return std::string();
}

void CameraBubble::CloseCamera() {
  running_ = false;
  if (thread_.joinable()) thread_.join();
  SafeRelease(&reader_);
  if (source_) {
    source_->Shutdown();
    SafeRelease(&source_);
  }
  std::lock_guard<std::mutex> lock(frame_mutex_);
  has_frame_ = false;
}

void CameraBubble::CaptureLoop() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  UINT32 width = 0;
  UINT32 height = 0;
  {
    IMFMediaType* current = nullptr;
    if (SUCCEEDED(reader_->GetCurrentMediaType(
            static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
            &current))) {
      MFGetAttributeSize(current, MF_MT_FRAME_SIZE, &width, &height);
      SafeRelease(&current);
    }
  }
  const int w = static_cast<int>(width);
  const int h = static_cast<int>(height);

  while (running_ && w > 0 && h > 0) {
    DWORD stream = 0;
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    IMFSample* sample = nullptr;
    HRESULT hr = reader_->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, &stream,
        &flags, &timestamp, &sample);
    if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM) ||
        (flags & MF_SOURCE_READERF_ERROR)) {
      SafeRelease(&sample);
      break;
    }
    if (!sample) continue;

    IMFMediaBuffer* buffer = nullptr;
    if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buffer))) {
      BYTE* scan0 = nullptr;
      LONG pitch = 0;
      IMF2DBuffer* buffer2d = nullptr;
      bool locked2d = false;
      BYTE* data = nullptr;
      if (SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&buffer2d))) &&
          SUCCEEDED(buffer2d->Lock2D(&scan0, &pitch))) {
        locked2d = true;
      } else {
        DWORD max_length = 0;
        DWORD current_length = 0;
        if (SUCCEEDED(buffer->Lock(&data, &max_length, &current_length))) {
          // RGB32 from the video processor is bottom-up by default.
          pitch = -static_cast<LONG>(w * 4);
          scan0 = data + static_cast<size_t>(h - 1) * static_cast<size_t>(w) * 4;
        }
      }
      if (scan0) {
        std::lock_guard<std::mutex> lock(frame_mutex_);
        frame_.resize(static_cast<size_t>(w) * static_cast<size_t>(h));
        for (int y = 0; y < h; ++y) {
          const BYTE* row = scan0 + static_cast<ptrdiff_t>(y) * pitch;
          std::memcpy(&frame_[static_cast<size_t>(y) * static_cast<size_t>(w)],
                      row, static_cast<size_t>(w) * 4);
        }
        frame_width_ = w;
        frame_height_ = h;
        has_frame_ = true;
      }
      if (locked2d) {
        buffer2d->Unlock2D();
      } else if (data) {
        buffer->Unlock();
      }
      SafeRelease(&buffer2d);
      SafeRelease(&buffer);
      if (hwnd_) PostMessage(hwnd_, kFrameMessage, 0, 0);
    }
    SafeRelease(&sample);
  }
  CoUninitialize();
}

std::string CameraBubble::Show(int diameter_logical, bool circle,
                               const std::wstring& device, HWND anchor) {
  if (!EnsureWindow()) return "Could not create the camera window.";
  diameter_logical_ = std::clamp(diameter_logical, 96, 480);
  circle_ = circle;

  if (!reader_ || device != device_) {
    CloseCamera();
    std::string error = OpenCamera(device);
    if (!error.empty()) {
      Hide();
      return error;
    }
    running_ = true;
    thread_ = std::thread([this]() { CaptureLoop(); });
  }

  int dpi = static_cast<int>(GetDpiForWindow(anchor ? anchor : hwnd_));
  if (dpi <= 0) dpi = 96;
  const int size = diameter_logical_ * dpi / 96 + kMargin * 2;
  if (!EnsureSurface(size)) return "Could not draw the camera bubble.";

  if (!positioned_) {
    // Start in the bottom-left corner of the app's monitor.
    HMONITOR monitor = MonitorFromWindow(anchor ? anchor : hwnd_,
                                         MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO info = {};
    info.cbSize = sizeof(info);
    GetMonitorInfo(monitor, &info);
    const int pad = 32 * dpi / 96;
    SetWindowPos(hwnd_, HWND_TOPMOST, info.rcWork.left + pad,
                 info.rcWork.bottom - size - pad, size, size,
                 SWP_NOACTIVATE);
    positioned_ = true;
  }
  visible_ = true;
  Render();
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  return std::string();
}

void CameraBubble::Hide() {
  visible_ = false;
  if (hwnd_) ShowWindow(hwnd_, SW_HIDE);
  CloseCamera();
  device_.clear();
}

bool CameraBubble::EnsureSurface(int size) {
  if (bits_ && size == size_) return true;
  ReleaseSurface();
  HDC screen = GetDC(nullptr);
  mem_dc_ = CreateCompatibleDC(screen);
  ReleaseDC(nullptr, screen);
  if (!mem_dc_) return false;
  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = size;
  bmi.bmiHeader.biHeight = -size;
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
  return true;
}

void CameraBubble::ReleaseSurface() {
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

void CameraBubble::Render() {
  if (!visible_ || !bits_ || !hwnd_) return;
  const int n = size_;
  const double inner = static_cast<double>(n - kMargin * 2);
  const double radius = circle_ ? inner / 2.0 : inner * 0.18;
  const double ring = std::max(2.0, inner / 80.0);

  std::lock_guard<std::mutex> lock(frame_mutex_);
  const bool have = has_frame_ && frame_width_ > 0 && frame_height_ > 0;
  // Centre-crop the camera frame to a square.
  const int side = have ? std::min(frame_width_, frame_height_) : 1;
  const int crop_x = have ? (frame_width_ - side) / 2 : 0;
  const int crop_y = have ? (frame_height_ - side) / 2 : 0;
  const double scale = static_cast<double>(side) / inner;

  for (int y = 0; y < n; ++y) {
    for (int x = 0; x < n; ++x) {
      const double lx = x + 0.5 - kMargin;
      const double ly = y + 0.5 - kMargin;
      const double cover = RoundedRectCoverage(lx, ly, inner, inner, radius);
      if (cover <= 0.0) {
        bits_[y * n + x] = 0;
        continue;
      }
      // Distance inside the edge, for the white ring.
      const double inside = std::min({lx, ly, inner - lx, inner - ly});
      double r = 30, g = 30, b = 34;
      if (have) {
        // Mirror horizontally (selfie view).
        int sx = crop_x + side - 1 -
                 static_cast<int>(std::clamp(lx, 0.0, inner - 1) * scale);
        int sy = crop_y + static_cast<int>(std::clamp(ly, 0.0, inner - 1) * scale);
        sx = std::clamp(sx, 0, frame_width_ - 1);
        sy = std::clamp(sy, 0, frame_height_ - 1);
        const uint32_t p =
            frame_[static_cast<size_t>(sy) * static_cast<size_t>(frame_width_) +
                   static_cast<size_t>(sx)];
        r = static_cast<double>((p >> 16) & 0xFF);
        g = static_cast<double>((p >> 8) & 0xFF);
        b = static_cast<double>(p & 0xFF);
      }
      // Ring: blend toward white near the edge (circle uses radial distance).
      double edge;
      if (circle_) {
        const double dx = lx - inner / 2.0;
        const double dy = ly - inner / 2.0;
        edge = radius - std::sqrt(dx * dx + dy * dy);
      } else {
        edge = inside;
      }
      const double ring_mix = Clamp01(ring - edge + 0.5);
      r = r + (255.0 - r) * ring_mix;
      g = g + (255.0 - g) * ring_mix;
      b = b + (255.0 - b) * ring_mix;
      const double a = cover;
      const auto pa = static_cast<uint32_t>(std::lround(a * 255.0));
      const auto pr = static_cast<uint32_t>(std::lround(r * a));
      const auto pg = static_cast<uint32_t>(std::lround(g * a));
      const auto pb = static_cast<uint32_t>(std::lround(b * a));
      bits_[y * n + x] = (pa << 24) | (pr << 16) | (pg << 8) | pb;
    }
  }

  RECT rect;
  GetWindowRect(hwnd_, &rect);
  POINT dst = {rect.left, rect.top};
  SIZE sz = {n, n};
  POINT src = {0, 0};
  BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  HDC screen = GetDC(nullptr);
  UpdateLayeredWindow(hwnd_, screen, &dst, &sz, mem_dc_, &src, 0, &blend,
                      ULW_ALPHA);
  ReleaseDC(nullptr, screen);
}

LRESULT CALLBACK CameraBubble::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    return DefWindowProc(hwnd, message, wparam, lparam);
  }
  auto* self =
      reinterpret_cast<CameraBubble*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  switch (message) {
    case kFrameMessage:
      if (self) self->Render();
      return 0;
    case WM_NCHITTEST:
      // Drag the bubble from anywhere on it.
      return HTCAPTION;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_DPICHANGED:
      return 0;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
