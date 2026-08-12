#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#include <string.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// ---- drag a file out of the window (channel "elyxr/dragout") --------------
//
// Flutter doesn't offer drag-out on Linux, so this is the native side: Dart
// says "the user grabbed file X" (beginDrag); we start an operating-system drag
// using XDS (X Direct Save), the standard protocol where the drop target hands
// the source the exact path to save to. On drop we read that path and ask Dart
// to download the server file straight there (writeTo) — no copy on the client.
static FlMethodChannel* g_dragout_channel = nullptr;
static GtkWidget* g_dragout_widget = nullptr;  // the FlView
static gchar* g_drag_server_path = nullptr;    // trove-relative path being dragged
static gchar* g_drag_filename = nullptr;       // basename shown to the desktop

static GdkAtom xds_atom() {
  return gdk_atom_intern_static_string("XdndDirectSave0");
}
static GdkAtom text_plain_atom() {
  return gdk_atom_intern_static_string("text/plain");
}

// The drop target writes the chosen save path (a file:// URI) into the
// XdndDirectSave0 property on our window; read it back.
static gchar* read_xds_target(GdkWindow* window) {
  GdkAtom actual_type;
  gint actual_format = 0;
  gint length = 0;
  guchar* data = nullptr;
  if (!gdk_property_get(window, xds_atom(), text_plain_atom(), 0, 2048, FALSE,
                        &actual_type, &actual_format, &length, &data)) {
    return nullptr;
  }
  gchar* out = g_strndup(reinterpret_cast<const gchar*>(data), length);
  g_free(data);
  return out;
}

// Fired when the drop target asks the source for the file. For XDS this is where
// we learn the destination and kick off the download to it.
static void on_drag_data_get(GtkWidget* widget, GdkDragContext* context,
                             GtkSelectionData* selection, guint info,
                             guint time_, gpointer user_data) {
  (void)context;
  (void)info;
  (void)time_;
  (void)user_data;
  GdkWindow* win = gtk_widget_get_window(widget);
  gchar* uri = win ? read_xds_target(win) : nullptr;
  const char* status = "E";
  if (uri != nullptr && g_drag_server_path != nullptr) {
    gchar* dest = g_filename_from_uri(uri, nullptr, nullptr);
    if (dest == nullptr) dest = g_strdup(uri);  // may already be a plain path
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "path",
                             fl_value_new_string(g_drag_server_path));
    fl_value_set_string_take(args, "dest", fl_value_new_string(dest));
    if (g_dragout_channel != nullptr) {
      fl_method_channel_invoke_method(g_dragout_channel, "writeTo", args, nullptr,
                                      nullptr, nullptr);
    }
    g_free(dest);
    status = "S";
  }
  g_free(uri);
  gtk_selection_data_set(selection, gtk_selection_data_get_target(selection), 8,
                         reinterpret_cast<const guchar*>(status), 1);
}

static void begin_native_drag() {
  if (g_dragout_widget == nullptr || g_drag_filename == nullptr) return;
  GdkWindow* win = gtk_widget_get_window(g_dragout_widget);
  if (win == nullptr) return;
  // Advertise the filename we want saved (XDS step one).
  gdk_property_change(win, xds_atom(), text_plain_atom(), 8, GDK_PROP_MODE_REPLACE,
                      reinterpret_cast<const guchar*>(g_drag_filename),
                      static_cast<gint>(strlen(g_drag_filename)));
  GtkTargetList* targets = gtk_target_list_new(nullptr, 0);
  gtk_target_list_add(targets, xds_atom(), 0, 0);
  GdkEvent* event = gtk_get_current_event();
  gtk_drag_begin_with_coordinates(g_dragout_widget, targets, GDK_ACTION_COPY, 1,
                                  event, -1, -1);
  gtk_target_list_unref(targets);
  if (event != nullptr) gdk_event_free(event);
}

static void dragout_method_handler(FlMethodChannel* channel,
                                   FlMethodCall* method_call, gpointer user_data) {
  (void)channel;
  (void)user_data;
  const gchar* method = fl_method_call_get_name(method_call);
  if (strcmp(method, "beginDrag") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    FlValue* path = fl_value_lookup_string(args, "path");
    FlValue* name = fl_value_lookup_string(args, "name");
    g_clear_pointer(&g_drag_server_path, g_free);
    g_clear_pointer(&g_drag_filename, g_free);
    if (path != nullptr && fl_value_get_type(path) == FL_VALUE_TYPE_STRING) {
      g_drag_server_path = g_strdup(fl_value_get_string(path));
    }
    if (name != nullptr && fl_value_get_type(name) == FL_VALUE_TYPE_STRING) {
      g_drag_filename = g_strdup(fl_value_get_string(name));
    }
    begin_native_drag();
    fl_method_call_respond_success(method_call, nullptr, nullptr);
  } else {
    fl_method_call_respond_not_implemented(method_call, nullptr);
  }
}

// Wire the channel and the drag handler to the Flutter view.
static void register_dragout(FlView* view) {
  g_dragout_widget = GTK_WIDGET(view);
  gtk_drag_source_set(GTK_WIDGET(view), GDK_BUTTON1_MASK, nullptr, 0,
                      GDK_ACTION_COPY);
  g_signal_connect(view, "drag-data-get", G_CALLBACK(on_drag_data_get), nullptr);
  FlEngine* engine = fl_view_get_engine(view);
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_dragout_channel = fl_method_channel_new(messenger, "elyxr/dragout",
                                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_dragout_channel,
                                            dragout_method_handler, nullptr,
                                            nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  gtk_widget_show(toplevel);
  // Pin the window's base cursor to the normal arrow. This window is undecorated
  // AND transparent, and nothing else sets a cursor on it — so it inherits the
  // X11 root window's cursor, which is the crosshair. Flutter overrides this
  // per-widget (the click cursor on the screws, etc.); this fixes the default
  // underneath so bare/transparent regions never show the crosshair. Native, so
  // no Dart rebuild ever affected it — which is why it survived every update.
  GdkWindow* gdk_window = gtk_widget_get_window(toplevel);
  if (gdk_window != nullptr) {
    GdkDisplay* display = gtk_widget_get_display(toplevel);
    GdkCursor* cursor = gdk_cursor_new_from_name(display, "default");
    if (cursor != nullptr) {
      gdk_window_set_cursor(gdk_window, cursor);
      g_object_unref(cursor);
    }
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // The metal chassis IS the window: no title bar. Resizable so it can be
  // fitted to short screens (the Flutter side scales the chassis to the window).
  gtk_window_set_title(window, "Elyxr");
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_resizable(window, TRUE);
  // Taskbar / alt-tab icon, from the icon the installer puts in the user's icon
  // theme under the app id (which the desktop matches the window against).
  gtk_window_set_icon_name(window, APPLICATION_ID);

  // Transparent window, so the chassis's rounded corners show the desktop
  // behind them instead of a black box. Needs a compositing desktop (Zorin,
  // GNOME, etc. have this on by default).
  GdkScreen* win_screen = gtk_widget_get_screen(GTK_WIDGET(window));
  GdkVisual* rgba_visual = gdk_screen_get_rgba_visual(win_screen);
  if (rgba_visual != nullptr && gdk_screen_is_composited(win_screen)) {
    gtk_widget_set_visual(GTK_WIDGET(window), rgba_visual);
    gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);
  }

  // The window is the chassis (440x944, the Galaxy S22 Ultra screen proportion)
  // plus a 42px transparent glow ring on every side (524x1028,
  // kWindowWidth/Height in Dart) — the room the max-saturation glow bleeds into
  // so it isn't sliced at the edge. The chassis inside renders at full size;
  // only if the screen is too short do we open smaller (keeping the shape) and
  // let the Flutter side scale to fit.
  //
  // The work area is what's left after the panel/taskbar — that's what makes it
  // the work area — so it is used as-is. Subtracting a second panel's worth on
  // top of it cost the app real size for nothing: on a 1080p screen it capped
  // the window at 968 and the Flutter side then scaled the chassis to 91.7%,
  // which is why Linux rendered visibly smaller than Windows.
  gint win_w = 524, win_h = 1028;
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
  if (monitor == nullptr && gdk_display_get_n_monitors(display) > 0) {
    monitor = gdk_display_get_monitor(display, 0);
  }
  if (monitor != nullptr) {
    GdkRectangle area;
    gdk_monitor_get_workarea(monitor, &area);
    if (area.height > 0 && win_h > area.height) {
      win_h = area.height;
      win_w = (gint)(win_h * (524.0 / 1028.0) + 0.5);
    }
  }
  gtk_window_set_default_size(window, win_w, win_h);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Transparent so the Flutter side (the metal chassis) is all that shows.
  gdk_rgba_parse(&background_color, "#00000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  register_dragout(view);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
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
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
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
