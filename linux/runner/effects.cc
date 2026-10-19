#include "effects.h"

#include <signal.h>
#include <sys/types.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

namespace {

constexpr char kChannel[] = "screen_recorder_app/windows";

// Same look as the Windows overlay (logical pixels).
constexpr double kHaloRadius = 22.0;
constexpr double kRingWidth = 2.5;
constexpr double kRippleMaxRadius = 54.0;
constexpr double kRippleWidth = 3.0;
constexpr gint64 kRippleDurationUs = 450000;
constexpr int kOverlaySize =
    static_cast<int>((kRippleMaxRadius + kRippleWidth + 4) * 2);

double clamp01(double v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

bool is_x11() {
#ifdef GDK_WINDOWING_X11
  GdkDisplay* display = gdk_display_get_default();
  return display != nullptr && GDK_IS_X11_DISPLAY(display);
#else
  return false;
#endif
}

// Makes [window] a transparent, undecorated, always-on-top popup.
// Returns false without a compositor (no transparency available).
bool make_floating(GtkWidget* window) {
  GdkScreen* screen = gtk_widget_get_screen(window);
  GdkVisual* visual = gdk_screen_get_rgba_visual(screen);
  if (visual == nullptr || !gdk_screen_is_composited(screen)) return false;
  gtk_widget_set_visual(window, visual);
  gtk_widget_set_app_paintable(window, TRUE);
  gtk_window_set_keep_above(GTK_WINDOW(window), TRUE);
  gtk_window_set_skip_taskbar_hint(GTK_WINDOW(window), TRUE);
  gtk_window_set_skip_pager_hint(GTK_WINDOW(window), TRUE);
  gtk_window_set_accept_focus(GTK_WINDOW(window), FALSE);
  gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
  return true;
}

void clear(cairo_t* cr) {
  cairo_save(cr);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgba(cr, 0, 0, 0, 0);
  cairo_paint(cr);
  cairo_restore(cr);
}

// ------------------------------------------------------------ halo ----

struct Ripple {
  gint64 start;
  bool right;
};

struct CursorOverlay {
  GtkWidget* window = nullptr;
  guint timer = 0;
  bool halo = true;
  bool ripples = true;
  bool pressed = false;
  bool left_was_down = false;
  bool right_was_down = false;
  std::vector<Ripple> active;
  gint64 last_raise = 0;
};

CursorOverlay g_overlay;

gboolean overlay_draw(GtkWidget* widget, cairo_t* cr, gpointer) {
  (void)widget;
  clear(cr);
  const double c = kOverlaySize / 2.0;
  const gint64 now = g_get_monotonic_time();
  if (g_overlay.halo) {
    const double r = kHaloRadius * (g_overlay.pressed ? 0.85 : 1.0);
    cairo_arc(cr, c, c, r, 0, 2 * M_PI);
    cairo_set_source_rgba(cr, 1.0, 214 / 255.0, 0, g_overlay.pressed ? 0.45 : 0.28);
    cairo_fill_preserve(cr);
    cairo_set_line_width(cr, kRingWidth);
    cairo_set_source_rgba(cr, 1.0, 214 / 255.0, 0, g_overlay.pressed ? 0.95 : 0.8);
    cairo_stroke(cr);
  }
  for (const auto& ripple : g_overlay.active) {
    const double p = clamp01(static_cast<double>(now - ripple.start) / kRippleDurationUs);
    const double eased = 1.0 - (1.0 - p) * (1.0 - p);
    const double radius = kHaloRadius + (kRippleMaxRadius - kHaloRadius) * eased;
    cairo_new_path(cr);
    cairo_arc(cr, c, c, radius, 0, 2 * M_PI);
    cairo_set_line_width(cr, kRippleWidth * (1.0 - 0.5 * p));
    if (ripple.right) {
      cairo_set_source_rgba(cr, 66 / 255.0, 165 / 255.0, 245 / 255.0, 0.9 * (1 - p));
    } else {
      cairo_set_source_rgba(cr, 1.0, 214 / 255.0, 0, 0.9 * (1 - p));
    }
    cairo_stroke(cr);
  }
  return TRUE;
}

gboolean overlay_tick(gpointer) {
  if (g_overlay.window == nullptr) return G_SOURCE_REMOVE;
  GdkDisplay* display = gdk_display_get_default();
  GdkSeat* seat = gdk_display_get_default_seat(display);
  GdkDevice* pointer = seat ? gdk_seat_get_pointer(seat) : nullptr;
  if (pointer == nullptr) return G_SOURCE_CONTINUE;

  gint x = 0, y = 0;
  gdk_device_get_position(pointer, nullptr, &x, &y);
  GdkModifierType mask = static_cast<GdkModifierType>(0);
  gdk_device_get_state(pointer, gdk_get_default_root_window(), nullptr, &mask);
  const bool left = (mask & GDK_BUTTON1_MASK) != 0;
  const bool right = (mask & GDK_BUTTON3_MASK) != 0;
  const gint64 now = g_get_monotonic_time();

  if (g_overlay.ripples) {
    if (left && !g_overlay.left_was_down) g_overlay.active.push_back({now, false});
    if (right && !g_overlay.right_was_down) g_overlay.active.push_back({now, true});
  }
  g_overlay.left_was_down = left;
  g_overlay.right_was_down = right;
  g_overlay.pressed = left || right;
  g_overlay.active.erase(
      std::remove_if(g_overlay.active.begin(), g_overlay.active.end(),
                     [now](const Ripple& r) { return now - r.start > kRippleDurationUs; }),
      g_overlay.active.end());

  gtk_window_move(GTK_WINDOW(g_overlay.window), x - kOverlaySize / 2, y - kOverlaySize / 2);
  gtk_widget_queue_draw(g_overlay.window);
  if (now - g_overlay.last_raise > G_USEC_PER_SEC) {
    g_overlay.last_raise = now;
    GdkWindow* gdk = gtk_widget_get_window(g_overlay.window);
    if (gdk) gdk_window_raise(gdk);
  }
  return G_SOURCE_CONTINUE;
}

void overlay_realize(GtkWidget* widget, gpointer) {
  // Clicks go straight through to whatever is underneath.
  cairo_region_t* empty = cairo_region_create();
  gdk_window_input_shape_combine_region(gtk_widget_get_window(widget), empty, 0, 0);
  cairo_region_destroy(empty);
}

bool overlay_show(bool halo, bool ripples) {
  if (!is_x11() || (!halo && !ripples)) return false;
  g_overlay.halo = halo;
  g_overlay.ripples = ripples;
  if (g_overlay.window == nullptr) {
    GtkWidget* window = gtk_window_new(GTK_WINDOW_POPUP);
    if (!make_floating(window)) {
      gtk_widget_destroy(window);
      return false;
    }
    gtk_window_set_default_size(GTK_WINDOW(window), kOverlaySize, kOverlaySize);
    gtk_widget_set_size_request(window, kOverlaySize, kOverlaySize);
    g_signal_connect(window, "draw", G_CALLBACK(overlay_draw), nullptr);
    g_signal_connect(window, "realize", G_CALLBACK(overlay_realize), nullptr);
    g_overlay.window = window;
  }
  g_overlay.active.clear();
  overlay_tick(nullptr);
  gtk_widget_show(g_overlay.window);
  if (g_overlay.timer == 0) g_overlay.timer = g_timeout_add(15, overlay_tick, nullptr);
  return true;
}

void overlay_hide() {
  if (g_overlay.timer) {
    g_source_remove(g_overlay.timer);
    g_overlay.timer = 0;
  }
  if (g_overlay.window) {
    gtk_widget_destroy(g_overlay.window);
    g_overlay.window = nullptr;
  }
  g_overlay.active.clear();
}

// ---------------------------------------------------------- camera ----

constexpr int kMargin = 4;  // room for the white ring

struct CameraDevice {
  std::string name;
  std::string path;
};

std::string read_line(const std::string& path) {
  gchar* contents = nullptr;
  if (!g_file_get_contents(path.c_str(), &contents, nullptr, nullptr)) return "";
  std::string s(contents);
  g_free(contents);
  while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ')) s.pop_back();
  return s;
}

// Video capture nodes from sysfs. Each webcam usually has a capture node
// (index 0) plus a metadata node, which is skipped.
std::vector<CameraDevice> list_cameras() {
  std::vector<std::pair<int, CameraDevice>> found;
  GDir* dir = g_dir_open("/sys/class/video4linux", 0, nullptr);
  if (dir == nullptr) return {};
  while (const gchar* entry = g_dir_read_name(dir)) {
    if (!g_str_has_prefix(entry, "video")) continue;
    const std::string base = std::string("/sys/class/video4linux/") + entry;
    const std::string index = read_line(base + "/index");
    if (!index.empty() && index != "0") continue;
    std::string name = read_line(base + "/name");
    if (name.empty()) name = entry;
    found.push_back({atoi(entry + 5), {name, std::string("/dev/") + entry}});
  }
  g_dir_close(dir);
  std::sort(found.begin(), found.end(),
            [](const auto& a, const auto& b) { return a.first < b.first; });
  std::vector<CameraDevice> out;
  for (auto& f : found) out.push_back(f.second);
  return out;
}

std::string ffmpeg_path() {
  gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe) {
    gchar* dir = g_path_get_dirname(exe);
    gchar* candidate = g_build_filename(dir, "ffmpeg", nullptr);
    std::string result;
    if (g_file_test(candidate, G_FILE_TEST_IS_EXECUTABLE)) result = candidate;
    g_free(candidate);
    g_free(dir);
    g_free(exe);
    if (!result.empty()) return result;
  }
  return "ffmpeg";
}

struct CameraBubble {
  GtkWidget* window = nullptr;
  int diameter = 220;
  bool circle = true;
  bool flip = false;
  std::string device;
  bool placed = false;

  // Frames from FFmpeg (BGRA == cairo ARGB32 on little-endian).
  GPid pid = 0;
  int out_fd = -1;
  GIOChannel* channel = nullptr;
  guint io_watch = 0;
  guint child_watch = 0;
  int frame_px = 0;  // square frame size in device pixels
  std::vector<unsigned char> buffer;
  size_t filled = 0;
  cairo_surface_t* frame = nullptr;
  bool failed = false;

  bool dragging = false;
  int drag_dx = 0;
  int drag_dy = 0;
  guint raise_timer = 0;
};

CameraBubble g_camera;

int bubble_size() { return g_camera.diameter + kMargin * 2; }

void rounded_rect(cairo_t* cr, double x, double y, double w, double h, double r) {
  r = std::min(r, std::min(w, h) / 2);
  cairo_new_sub_path(cr);
  cairo_arc(cr, x + w - r, y + r, r, -M_PI / 2, 0);
  cairo_arc(cr, x + w - r, y + h - r, r, 0, M_PI / 2);
  cairo_arc(cr, x + r, y + h - r, r, M_PI / 2, M_PI);
  cairo_arc(cr, x + r, y + r, r, M_PI, 1.5 * M_PI);
  cairo_close_path(cr);
}

gboolean camera_draw(GtkWidget* widget, cairo_t* cr, gpointer) {
  (void)widget;
  clear(cr);
  const double inner = g_camera.diameter;
  const double radius = g_camera.circle ? inner / 2 : inner * 0.18;
  rounded_rect(cr, kMargin, kMargin, inner, inner, radius);
  cairo_save(cr);
  cairo_clip_preserve(cr);
  if (g_camera.frame) {
    cairo_save(cr);
    cairo_translate(cr, kMargin, kMargin);
    const double s = inner / std::max(1, g_camera.frame_px);
    cairo_scale(cr, s, s);
    cairo_set_source_surface(cr, g_camera.frame, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
    cairo_paint(cr);
    cairo_restore(cr);
  } else {
    cairo_set_source_rgb(cr, 0.11, 0.12, 0.15);
    cairo_paint(cr);
    cairo_set_source_rgba(cr, 1, 1, 1, 0.75);
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 13);
    const char* text = g_camera.failed ? "Camera unavailable" : "Starting camera…";
    cairo_text_extents_t ext;
    cairo_text_extents(cr, text, &ext);
    cairo_move_to(cr, kMargin + inner / 2 - ext.width / 2 - ext.x_bearing,
                  kMargin + inner / 2 - ext.height / 2 - ext.y_bearing);
    cairo_show_text(cr, text);
  }
  cairo_restore(cr);
  // White ring, like the Windows bubble.
  cairo_set_line_width(cr, std::max(2.0, inner / 80.0) * 1.5);
  cairo_set_source_rgba(cr, 1, 1, 1, 0.95);
  cairo_stroke(cr);
  return TRUE;
}

void camera_stop_ffmpeg() {
  if (g_camera.io_watch) {
    g_source_remove(g_camera.io_watch);
    g_camera.io_watch = 0;
  }
  if (g_camera.channel) {
    g_io_channel_shutdown(g_camera.channel, FALSE, nullptr);
    g_io_channel_unref(g_camera.channel);
    g_camera.channel = nullptr;
    g_camera.out_fd = -1;
  }
  if (g_camera.child_watch) {
    g_source_remove(g_camera.child_watch);
    g_camera.child_watch = 0;
  }
  if (g_camera.pid > 0) {
    kill(g_camera.pid, SIGTERM);
    g_spawn_close_pid(g_camera.pid);
    g_camera.pid = 0;
  }
  g_camera.filled = 0;
}

gboolean camera_read(GIOChannel*, GIOCondition condition, gpointer) {
  bool got_frame = false;
  if (condition & G_IO_IN) {
    const size_t frame_bytes = g_camera.buffer.size();
    for (;;) {
      const ssize_t n = read(g_camera.out_fd, g_camera.buffer.data() + g_camera.filled,
                             frame_bytes - g_camera.filled);
      if (n > 0) {
        g_camera.filled += static_cast<size_t>(n);
        if (g_camera.filled == frame_bytes) {
          cairo_surface_flush(g_camera.frame);
          unsigned char* dst = cairo_image_surface_get_data(g_camera.frame);
          const int stride = cairo_image_surface_get_stride(g_camera.frame);
          const int row = g_camera.frame_px * 4;
          for (int y = 0; y < g_camera.frame_px; ++y) {
            memcpy(dst + y * stride, g_camera.buffer.data() + y * row, row);
          }
          cairo_surface_mark_dirty(g_camera.frame);
          g_camera.filled = 0;
          got_frame = true;
        }
        continue;
      }
      if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) break;
      // EOF or error: FFmpeg stopped.
      g_camera.failed = true;
      g_camera.io_watch = 0;
      if (g_camera.window) gtk_widget_queue_draw(g_camera.window);
      return G_SOURCE_REMOVE;
    }
  } else if (condition & (G_IO_HUP | G_IO_ERR)) {
    g_camera.failed = true;
    g_camera.io_watch = 0;
    if (g_camera.window) gtk_widget_queue_draw(g_camera.window);
    return G_SOURCE_REMOVE;
  }
  if (got_frame && g_camera.window) gtk_widget_queue_draw(g_camera.window);
  return G_SOURCE_CONTINUE;
}

void camera_child_exited(GPid pid, gint, gpointer) {
  g_spawn_close_pid(pid);
  if (pid == g_camera.pid) {
    g_camera.pid = 0;
    g_camera.child_watch = 0;
  }
}

// Starts FFmpeg reading the webcam and writing square, mirrored BGRA
// frames to stdout. Returns an error message, or "" on success.
std::string camera_start_ffmpeg(const std::string& path, int scale) {
  camera_stop_ffmpeg();
  g_camera.failed = false;
  g_camera.frame_px = std::max(32, g_camera.diameter * std::max(1, scale));
  const int px = g_camera.frame_px;
  if (g_camera.frame) cairo_surface_destroy(g_camera.frame);
  g_camera.frame = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, px, px);
  g_camera.buffer.assign(static_cast<size_t>(px) * px * 4, 0);
  g_camera.filled = 0;

  gchar* filter = g_strdup_printf(
      "crop='min(iw,ih)':'min(iw,ih)',scale=%d:%d,hflip%s,format=bgra", px, px,
      g_camera.flip ? ",vflip" : "");
  const std::string ffmpeg = ffmpeg_path();
  const gchar* argv[] = {ffmpeg.c_str(), "-hide_banner", "-loglevel", "error",
                         "-f", "v4l2", "-i", path.c_str(), "-vf", filter,
                         "-r", "30", "-f", "rawvideo", "-", nullptr};
  GError* error = nullptr;
  GPid pid = 0;
  int out_fd = -1;
  const gboolean ok = g_spawn_async_with_pipes(
      nullptr, const_cast<gchar**>(argv), nullptr,
      static_cast<GSpawnFlags>(G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_SEARCH_PATH |
                               G_SPAWN_STDERR_TO_DEV_NULL),
      nullptr, nullptr, &pid, nullptr, &out_fd, nullptr, &error);
  g_free(filter);
  if (!ok) {
    std::string message = "Could not start the camera (FFmpeg is missing).";
    if (error) g_error_free(error);
    return message;
  }
  g_camera.pid = pid;
  g_camera.out_fd = out_fd;
  g_camera.channel = g_io_channel_unix_new(out_fd);
  g_io_channel_set_encoding(g_camera.channel, nullptr, nullptr);
  g_io_channel_set_buffered(g_camera.channel, FALSE);
  g_io_channel_set_flags(g_camera.channel, G_IO_FLAG_NONBLOCK, nullptr);
  g_camera.io_watch = g_io_add_watch(
      g_camera.channel, static_cast<GIOCondition>(G_IO_IN | G_IO_HUP | G_IO_ERR),
      camera_read, nullptr);
  g_camera.child_watch = g_child_watch_add(pid, camera_child_exited, nullptr);
  return "";
}

void camera_move_to_corner(int corner) {
  if (g_camera.window == nullptr) return;
  GdkDisplay* display = gdk_display_get_default();
  GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
  if (monitor == nullptr) monitor = gdk_display_get_monitor(display, 0);
  if (monitor == nullptr) return;
  GdkRectangle work;
  gdk_monitor_get_workarea(monitor, &work);
  const int pad = 32;
  const int size = bubble_size();
  const bool right = corner == 1 || corner == 3;
  const bool bottom = corner == 2 || corner == 3;
  const int x = right ? work.x + work.width - size - pad : work.x + pad;
  const int y = bottom ? work.y + work.height - size - pad : work.y + pad;
  gtk_window_move(GTK_WINDOW(g_camera.window), x, y);
}

gboolean camera_press(GtkWidget* widget, GdkEventButton* event, gpointer) {
  if (event->button != 1) return FALSE;
  gint wx = 0, wy = 0;
  gtk_window_get_position(GTK_WINDOW(widget), &wx, &wy);
  g_camera.drag_dx = static_cast<int>(event->x_root) - wx;
  g_camera.drag_dy = static_cast<int>(event->y_root) - wy;
  g_camera.dragging = true;
  return TRUE;
}

gboolean camera_motion(GtkWidget* widget, GdkEventMotion* event, gpointer) {
  if (!g_camera.dragging) return FALSE;
  gtk_window_move(GTK_WINDOW(widget), static_cast<int>(event->x_root) - g_camera.drag_dx,
                  static_cast<int>(event->y_root) - g_camera.drag_dy);
  return TRUE;
}

gboolean camera_release(GtkWidget*, GdkEventButton*, gpointer) {
  g_camera.dragging = false;
  return TRUE;
}

gboolean camera_raise(gpointer) {
  if (g_camera.window == nullptr) return G_SOURCE_REMOVE;
  GdkWindow* gdk = gtk_widget_get_window(g_camera.window);
  if (gdk) gdk_window_raise(gdk);
  // Keep the halo above the bubble.
  if (g_overlay.window) {
    GdkWindow* halo = gtk_widget_get_window(g_overlay.window);
    if (halo) gdk_window_raise(halo);
  }
  return G_SOURCE_CONTINUE;
}

std::string camera_show(int diameter, bool circle, bool flip, const std::string& device,
                        int corner) {
  if (!is_x11()) return "The face camera needs an X11 session on Linux.";
  const auto cameras = list_cameras();
  if (cameras.empty()) return "No camera was found. Plug one in and try again.";
  std::string path = cameras.front().path;
  for (const auto& camera : cameras) {
    if (camera.name == device) {
      path = camera.path;
      break;
    }
  }

  const bool restart = g_camera.window == nullptr || g_camera.pid == 0 ||
                       diameter != g_camera.diameter || flip != g_camera.flip ||
                       path != g_camera.device;
  g_camera.diameter = std::max(60, diameter);
  g_camera.circle = circle;
  g_camera.flip = flip;
  g_camera.device = path;

  if (g_camera.window == nullptr) {
    GtkWidget* window = gtk_window_new(GTK_WINDOW_POPUP);
    if (!make_floating(window)) {
      gtk_widget_destroy(window);
      return "The face camera needs a desktop with compositing (transparency) turned on.";
    }
    gtk_widget_add_events(window, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK |
                                      GDK_POINTER_MOTION_MASK);
    g_signal_connect(window, "draw", G_CALLBACK(camera_draw), nullptr);
    g_signal_connect(window, "button-press-event", G_CALLBACK(camera_press), nullptr);
    g_signal_connect(window, "motion-notify-event", G_CALLBACK(camera_motion), nullptr);
    g_signal_connect(window, "button-release-event", G_CALLBACK(camera_release), nullptr);
    g_camera.window = window;
    g_camera.placed = false;
  }
  const int size = bubble_size();
  gtk_widget_set_size_request(g_camera.window, size, size);
  gtk_window_resize(GTK_WINDOW(g_camera.window), size, size);
  if (!g_camera.placed) {
    gtk_widget_show(g_camera.window);
    camera_move_to_corner(corner);
    g_camera.placed = true;
  }
  gtk_widget_show(g_camera.window);
  if (g_camera.raise_timer == 0) g_camera.raise_timer = g_timeout_add(1000, camera_raise, nullptr);
  camera_raise(nullptr);

  if (restart) {
    const int scale = gtk_widget_get_scale_factor(g_camera.window);
    const std::string error = camera_start_ffmpeg(path, scale);
    if (!error.empty()) return error;
    if (g_camera.frame) cairo_surface_set_device_scale(g_camera.frame, 1, 1);
  }
  gtk_widget_queue_draw(g_camera.window);
  return "";
}

void camera_hide() {
  camera_stop_ffmpeg();
  if (g_camera.raise_timer) {
    g_source_remove(g_camera.raise_timer);
    g_camera.raise_timer = 0;
  }
  if (g_camera.window) {
    gtk_widget_destroy(g_camera.window);
    g_camera.window = nullptr;
  }
  if (g_camera.frame) {
    cairo_surface_destroy(g_camera.frame);
    g_camera.frame = nullptr;
  }
  g_camera.placed = false;
}

// --------------------------------------------------------- channel ----

bool arg_bool(FlValue* args, const char* key, bool fallback) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* v = fl_value_lookup_string(args, key);
  return (v && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL) ? fl_value_get_bool(v) : fallback;
}

int arg_int(FlValue* args, const char* key, int fallback) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* v = fl_value_lookup_string(args, key);
  return (v && fl_value_get_type(v) == FL_VALUE_TYPE_INT) ? static_cast<int>(fl_value_get_int(v))
                                                          : fallback;
}

std::string arg_string(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return "";
  FlValue* v = fl_value_lookup_string(args, key);
  return (v && fl_value_get_type(v) == FL_VALUE_TYPE_STRING) ? fl_value_get_string(v) : "";
}

void method_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlValue) result = nullptr;

  if (g_strcmp0(method, "showCursorOverlay") == 0) {
    result = fl_value_new_bool(overlay_show(arg_bool(args, "halo", true),
                                            arg_bool(args, "ripples", true)));
  } else if (g_strcmp0(method, "hideCursorOverlay") == 0) {
    overlay_hide();
    result = fl_value_new_bool(TRUE);
  } else if (g_strcmp0(method, "listCameras") == 0) {
    result = fl_value_new_list();
    for (const auto& camera : list_cameras()) {
      fl_value_append_take(result, fl_value_new_string(camera.name.c_str()));
    }
  } else if (g_strcmp0(method, "showCamera") == 0) {
    const std::string error =
        camera_show(arg_int(args, "diameter", 220), arg_bool(args, "circle", true),
                    arg_bool(args, "flip", false), arg_string(args, "device"),
                    arg_int(args, "corner", 2));
    result = error.empty() ? fl_value_new_null() : fl_value_new_string(error.c_str());
  } else if (g_strcmp0(method, "moveCamera") == 0) {
    const int corner = (args && fl_value_get_type(args) == FL_VALUE_TYPE_INT)
                           ? static_cast<int>(fl_value_get_int(args))
                           : 2;
    camera_move_to_corner(corner);
    result = fl_value_new_bool(TRUE);
  } else if (g_strcmp0(method, "hideCamera") == 0) {
    camera_hide();
    result = fl_value_new_bool(TRUE);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  fl_method_call_respond_success(call, result, nullptr);
}

FlMethodChannel* g_channel = nullptr;

}  // namespace

void effects_register(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel = fl_method_channel_new(messenger, kChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, method_call, nullptr, nullptr);
}
