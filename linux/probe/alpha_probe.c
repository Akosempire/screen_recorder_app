// Standalone GTK3 probe: a 200×200 window with a fully transparent cutout.
//
// This is not the recording chip and not the Flutter selector. Run it on an
// X11 + compositing session and look at the hole: you should see the desktop
// (or a window behind), not black/magenta. If the hole is opaque on GNOME
// Wayland, that is expected — do not "fix" it by rewriting the selector.
//
//   cmake --build build/linux/x64/debug --target alpha_probe
//   ./build/linux/x64/debug/alpha_probe

/* G_APPLICATION_DEFAULT_FLAGS needs GLib 2.74 (Ubuntu 22.04 has 2.72). */
#include <glib.h>
#if GLIB_CHECK_VERSION(2, 74, 0)
#define PROBE_APP_FLAGS G_APPLICATION_DEFAULT_FLAGS
#else
#define PROBE_APP_FLAGS G_APPLICATION_FLAGS_NONE
#endif
#include <gtk/gtk.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

static const int kWindowSize = 200;
static const int kHoleSize = 80;

static const char* display_name(GdkScreen* screen) {
#ifdef GDK_WINDOWING_X11
  if (GDK_IS_X11_SCREEN(screen)) {
    return "x11";
  }
#endif
#ifdef GDK_WINDOWING_WAYLAND
  if (GDK_IS_WAYLAND_DISPLAY(gdk_screen_get_display(screen))) {
    return "wayland";
  }
#endif
  (void)screen;
  return "unknown";
}

static gboolean on_draw(GtkWidget* widget, cairo_t* cr, gpointer user_data) {
  (void)user_data;
  GtkAllocation alloc;
  gtk_widget_get_allocation(widget, &alloc);

  const int cell = 16;
  for (int y = 0; y < alloc.height; y += cell) {
    for (int x = 0; x < alloc.width; x += cell) {
      const gboolean dark = ((x / cell) + (y / cell)) % 2 == 0;
      if (dark) {
        cairo_set_source_rgb(cr, 0.18, 0.20, 0.24);
      } else {
        cairo_set_source_rgb(cr, 0.32, 0.36, 0.42);
      }
      cairo_rectangle(cr, x, y, cell, cell);
      cairo_fill(cr);
    }
  }

  const double hole_x = (alloc.width - kHoleSize) / 2.0;
  const double hole_y = (alloc.height - kHoleSize) / 2.0;
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.0);
  cairo_rectangle(cr, hole_x, hole_y, kHoleSize, kHoleSize);
  cairo_fill(cr);
  cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
  return FALSE;
}

static void on_activate(GtkApplication* app, gpointer user_data) {
  (void)user_data;
  GtkWidget* window = gtk_application_window_new(app);
  gtk_window_set_title(GTK_WINDOW(window),
                       "Alpha probe — desktop should show in the hole");
  gtk_window_set_default_size(GTK_WINDOW(window), kWindowSize, kWindowSize);
  gtk_window_set_resizable(GTK_WINDOW(window), FALSE);
  gtk_widget_set_app_paintable(window, TRUE);

  GdkScreen* screen = gtk_window_get_screen(GTK_WINDOW(window));
  const char* display = display_name(screen);
  const gboolean is_x11 = g_strcmp0(display, "x11") == 0;
  const gboolean composited = gdk_screen_is_composited(screen);
  GdkVisual* rgba = gdk_screen_get_rgba_visual(screen);
  const gboolean has_rgba = rgba != NULL;

  // RGBA visual is an X11 compositing-WM path. On Wayland this is a no-op,
  // not "prepared."
  if (is_x11 && composited && rgba != NULL) {
    gtk_widget_set_visual(window, rgba);
  }

  GtkWidget* drawing = gtk_drawing_area_new();
  gtk_widget_set_app_paintable(drawing, TRUE);
  gtk_widget_set_size_request(drawing, kWindowSize, kWindowSize);
  g_signal_connect(drawing, "draw", G_CALLBACK(on_draw), NULL);
  gtk_container_add(GTK_CONTAINER(window), drawing);

  g_print("alpha_probe\n");
  g_print("  display:    %s\n", display);
  g_print("  composited: %s\n", composited ? "true" : "false");
  g_print("  rgba_visual:%s\n", has_rgba ? "true" : "false");
  if (!is_x11) {
    g_print("This is not X11. Do not enable LIVE_SELECTOR here, even if the\n");
    g_print("cutout looks interesting — GNOME/KDE Wayland stay on snapshot.\n");
  }
  g_print("Look at the center cutout. Desktop through the hole = pass.\n");
  g_print("Opaque black/magenta hole = do not enable the live selector.\n");

  gtk_widget_show_all(window);
}

int main(int argc, char** argv) {
  GtkApplication* app = gtk_application_new(
      "com.example.screen_recorder_app.alpha_probe",
      PROBE_APP_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
  const int status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
