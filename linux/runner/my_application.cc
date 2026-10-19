#include "my_application.h"

#include <cstring>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

#include "effects.h"
#include "flutter/generated_plugin_registrant.h"

static const gchar kNativeChannel[] = "screen_recorder_app/native_window";

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  FlMethodChannel* channel;
  gboolean is_x11;
  gboolean is_wayland;
  gboolean composited;
  gboolean has_rgba_visual;
  gboolean gl_has_alpha;
  gchar* parent_window;
  gboolean parent_export_started;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static gboolean screen_is_x11(GdkScreen* screen) {
#ifdef GDK_WINDOWING_X11
  return GDK_IS_X11_SCREEN(screen);
#else
  (void)screen;
  return FALSE;
#endif
}

static gboolean screen_is_wayland(GdkScreen* screen) {
#ifdef GDK_WINDOWING_WAYLAND
  return GDK_IS_WAYLAND_DISPLAY(gdk_screen_get_display(screen));
#else
  (void)screen;
  return FALSE;
#endif
}

static void watch_for_gl_area(GtkWidget* widget, MyApplication* self);

static void on_container_add(GtkContainer* container,
                             GtkWidget* child,
                             gpointer user_data) {
  (void)container;
  watch_for_gl_area(child, MY_APPLICATION(user_data));
}

static void on_gl_area_realize(GtkWidget* widget, gpointer user_data) {
  // Default realize is G_SIGNAL_RUN_FIRST, so a user realize handler is too
  // late for has_alpha. Keep this only as a last-chance log.
  (void)widget;
  MyApplication* self = MY_APPLICATION(user_data);
  if (!self->gl_has_alpha) {
    g_warning(
        "GtkGLArea realized without has_alpha; punch-through will not work");
  }
}

static void enable_gl_area_alpha(GtkWidget* gl_area, MyApplication* self) {
  if (gtk_widget_get_realized(gl_area)) {
    g_warning("GtkGLArea already realized; has_alpha cannot be applied");
    return;
  }
  gtk_gl_area_set_has_alpha(GTK_GL_AREA(gl_area), TRUE);
  self->gl_has_alpha = TRUE;
  g_signal_connect(gl_area, "realize", G_CALLBACK(on_gl_area_realize), self);
}

static void watch_child(GtkWidget* child, gpointer data) {
  watch_for_gl_area(child, MY_APPLICATION(data));
}

static void watch_for_gl_area(GtkWidget* widget, MyApplication* self) {
  if (widget == nullptr) {
    return;
  }
  if (GTK_IS_GL_AREA(widget)) {
    enable_gl_area_alpha(widget, self);
    return;
  }
  if (!GTK_IS_CONTAINER(widget)) {
    return;
  }
  // Catch a GtkGLArea at add-time, before realize / first frame.
  if (g_object_get_data(G_OBJECT(widget), "sr-gl-watch") == nullptr) {
    g_object_set_data(G_OBJECT(widget), "sr-gl-watch", GINT_TO_POINTER(1));
    g_signal_connect(widget, "add", G_CALLBACK(on_container_add), self);
  }
  gtk_container_forall(GTK_CONTAINER(widget), watch_child, self);
}

#ifdef GDK_WINDOWING_WAYLAND
static void wayland_exported_cb(GdkWindow* window,
                                const char* handle,
                                gpointer user_data) {
  (void)window;
  MyApplication* self = MY_APPLICATION(user_data);
  g_free(self->parent_window);
  self->parent_window = g_strdup_printf("wayland:%s", handle);
}

#endif

static GdkWindow* application_gdk_window(MyApplication* self) {
  if (self->window == nullptr) {
    return nullptr;
  }
  return gtk_widget_get_window(GTK_WIDGET(self->window));
}

static void export_parent_window(MyApplication* self) {
  GdkWindow* gdk_window = application_gdk_window(self);
  if (gdk_window == nullptr) {
    return;
  }
#ifdef GDK_WINDOWING_X11
  if (GDK_IS_X11_WINDOW(gdk_window)) {
    g_free(self->parent_window);
    self->parent_window = g_strdup_printf(
        "x11:0x%lx",
        static_cast<unsigned long>(gdk_x11_window_get_xid(gdk_window)));
    return;
  }
#endif
#ifdef GDK_WINDOWING_WAYLAND
  if (GDK_IS_WAYLAND_WINDOW(gdk_window)) {
    if (self->parent_window != nullptr || self->parent_export_started) {
      return;
    }
    self->parent_export_started = TRUE;
    if (!gdk_wayland_window_export_handle(gdk_window, wayland_exported_cb, self,
                                          nullptr)) {
      self->parent_export_started = FALSE;
    }
  }
#endif
}

static gint32 fl_value_as_int(FlValue* value) {
  if (value == nullptr) {
    return 0;
  }
  switch (fl_value_get_type(value)) {
    case FL_VALUE_TYPE_INT:
      return static_cast<gint32>(fl_value_get_int(value));
    case FL_VALUE_TYPE_FLOAT:
      return static_cast<gint32>(fl_value_get_float(value));
    default:
      return 0;
  }
}

static FlValue* capabilities_value(MyApplication* self) {
  const gchar* display_server = "unknown";
  if (self->is_x11) {
    display_server = "x11";
  } else if (self->is_wayland) {
    display_server = "wayland";
  }
  const gboolean probe_passed =
      self->is_x11 && self->composited && self->has_rgba_visual;

  g_autoptr(FlValue) result = fl_value_new_map();
  fl_value_set_string_take(result, "displayServer",
                           fl_value_new_string(display_server));
  fl_value_set_string_take(result, "composited",
                           fl_value_new_bool(self->composited));
  fl_value_set_string_take(result, "hasRgbaVisual",
                           fl_value_new_bool(self->has_rgba_visual));
  fl_value_set_string_take(result, "glHasAlpha",
                           fl_value_new_bool(self->gl_has_alpha));
  fl_value_set_string_take(result, "opaqueRegionSupported",
                           fl_value_new_bool(self->is_x11));
  fl_value_set_string_take(result, "probePassed",
                           fl_value_new_bool(probe_passed));
  return fl_value_ref(result);
}

static gboolean apply_opaque_region(MyApplication* self, FlValue* args) {
  if (!self->is_x11) {
    return FALSE;
  }
  GdkWindow* gdk_window = application_gdk_window(self);
  if (gdk_window == nullptr) {
    return FALSE;
  }

  cairo_region_t* region = cairo_region_create();
  FlValue* rects = nullptr;
  if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    rects = fl_value_lookup_string(args, "rects");
  } else if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_LIST) {
    rects = args;
  }
  if (rects != nullptr && fl_value_get_type(rects) == FL_VALUE_TYPE_LIST) {
    const size_t count = fl_value_get_length(rects);
    for (size_t i = 0; i < count; i++) {
      FlValue* item = fl_value_get_list_value(rects, i);
      if (item == nullptr || fl_value_get_type(item) != FL_VALUE_TYPE_MAP) {
        continue;
      }
      cairo_rectangle_int_t rect;
      rect.x = fl_value_as_int(fl_value_lookup_string(item, "x"));
      rect.y = fl_value_as_int(fl_value_lookup_string(item, "y"));
      rect.width = fl_value_as_int(fl_value_lookup_string(item, "width"));
      rect.height = fl_value_as_int(fl_value_lookup_string(item, "height"));
      if (rect.width <= 0 || rect.height <= 0) {
        continue;
      }
      cairo_region_union_rectangle(region, &rect);
    }
  }
  gdk_window_set_opaque_region(gdk_window, region);
  cairo_region_destroy(region);
  return TRUE;
}

static gboolean clear_opaque_region(MyApplication* self) {
  GdkWindow* gdk_window = application_gdk_window(self);
  if (gdk_window == nullptr) {
    return FALSE;
  }
  // NULL = the whole window may be non-opaque. Do not shrink the input
  // region; clicks on the hole must still hit this window.
  gdk_window_set_opaque_region(gdk_window, nullptr);
  return TRUE;
}

static gboolean set_fixed_bounds(MyApplication* self, FlValue* args) {
  if (self->window == nullptr || args == nullptr ||
      fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FALSE;
  }
  const gint x = fl_value_as_int(fl_value_lookup_string(args, "x"));
  const gint y = fl_value_as_int(fl_value_lookup_string(args, "y"));
  gint width = fl_value_as_int(fl_value_lookup_string(args, "width"));
  gint height = fl_value_as_int(fl_value_lookup_string(args, "height"));
  if (width < 1) {
    width = 1;
  }
  if (height < 1) {
    height = 1;
  }

  gtk_window_unfullscreen(self->window);
  gtk_window_unmaximize(self->window);
  gtk_window_set_resizable(self->window, TRUE);

  GdkGeometry geometry;
  memset(&geometry, 0, sizeof(geometry));
  geometry.min_width = width;
  geometry.min_height = height;
  geometry.max_width = width;
  geometry.max_height = height;
  gtk_window_set_geometry_hints(
      self->window, nullptr, &geometry,
      static_cast<GdkWindowHints>(GDK_HINT_MIN_SIZE | GDK_HINT_MAX_SIZE));
  gtk_window_set_default_size(self->window, width, height);
  gtk_window_resize(self->window, width, height);
  gtk_window_move(self->window, x, y);
  return TRUE;
}

static gboolean clear_fixed_bounds(MyApplication* self) {
  if (self->window == nullptr) {
    return FALSE;
  }
  gtk_window_set_geometry_hints(self->window, nullptr, nullptr,
                                static_cast<GdkWindowHints>(0));
  gtk_window_set_resizable(self->window, TRUE);
  return TRUE;
}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  (void)channel;
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(method, "getCapabilities") == 0) {
    g_autoptr(FlValue) result = capabilities_value(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "setOpaqueRegion") == 0) {
    const gboolean applied =
        apply_opaque_region(self, fl_method_call_get_args(method_call));
    g_autoptr(FlValue) result = fl_value_new_bool(applied);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "clearOpaqueRegion") == 0) {
    const gboolean cleared = clear_opaque_region(self);
    g_autoptr(FlValue) result = fl_value_new_bool(cleared);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "setFixedBounds") == 0) {
    const gboolean applied =
        set_fixed_bounds(self, fl_method_call_get_args(method_call));
    g_autoptr(FlValue) result = fl_value_new_bool(applied);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "clearFixedBounds") == 0) {
    const gboolean cleared = clear_fixed_bounds(self);
    g_autoptr(FlValue) result = fl_value_new_bool(cleared);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "getParentWindow") == 0) {
    export_parent_window(self);
    g_autoptr(FlValue) result = fl_value_new_string(
        self->parent_window != nullptr ? self->parent_window : "");
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to send response: %s", error->message);
  }
}

static void setup_method_channel(MyApplication* self, FlView* view) {
  FlEngine* engine = fl_view_get_engine(view);
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(messenger, kNativeChannel,
                                        FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_call_cb, self,
                                            nullptr);
  // Cursor halo and face-camera bubble.
  effects_register(messenger);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
  export_parent_window(self);
}

static void on_window_map(GtkWidget* widget, gpointer user_data) {
  (void)widget;
  export_parent_window(MY_APPLICATION(user_data));
}

static void on_window_destroy(GtkWidget* widget, gpointer user_data) {
  (void)widget;
  MyApplication* self = MY_APPLICATION(user_data);
  self->window = nullptr;
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_signal_connect(window, "destroy", G_CALLBACK(on_window_destroy), self);
  g_signal_connect(window, "map", G_CALLBACK(on_window_map), self);

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Screen Recorder");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Screen Recorder");
  }

  gtk_window_set_default_size(window, 460, 380);

  gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);

  GdkScreen* gdk_screen = gtk_window_get_screen(window);
  self->is_x11 = screen_is_x11(gdk_screen);
  self->is_wayland = screen_is_wayland(gdk_screen);
  self->composited = gdk_screen_is_composited(gdk_screen);
  GdkVisual* rgba_visual = gdk_screen_get_rgba_visual(gdk_screen);
  self->has_rgba_visual = rgba_visual != nullptr;

  // RGBA visual only when both gdk_screen_get_rgba_visual and
  // gdk_screen_is_composited are real (X11). On Wayland this is a no-op, not
  // "prepared."
  if (self->is_x11 && self->composited && rgba_visual != nullptr) {
    gtk_widget_set_visual(GTK_WIDGET(window), rgba_visual);
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);

  // Zero the struct first. gdk_rgba_parse("#00000000") is not a valid GDK
  // color (that is CSS #rrggbbaa) and ignoring the return used to pass stack
  // garbage into fl_view_set_background_color.
  GdkRGBA background_color;
  memset(&background_color, 0, sizeof(background_color));
  if (!gdk_rgba_parse(&background_color, "rgba(0,0,0,0)")) {
    background_color.red = 0;
    background_color.green = 0;
    background_color.blue = 0;
    background_color.alpha = 0;
  }
  fl_view_set_background_color(view, &background_color);

  // Flutter 3.41 renders through GtkDrawingArea. Older embeddings used
  // GtkGLArea — set has_alpha when that widget is created, before realize.
  watch_for_gl_area(GTK_WIDGET(view), self);

  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));
  watch_for_gl_area(GTK_WIDGET(view), self);

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  setup_method_channel(self, view);
  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  self->window = nullptr;
  g_clear_pointer(&self->parent_window, g_free);
  g_clear_object(&self->channel);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
