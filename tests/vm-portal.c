// Guest-only: drive real xdg-desktop-portal requests on a persistent D-Bus
// connection. The host harness interacts with the actual picker UIs via QMP.
#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <unistd.h>

static const char *desktop = "org.freedesktop.portal.Desktop";
static const char *object = "/org/freedesktop/portal/desktop";
static const char *cast = "org.freedesktop.portal.ScreenCast";
static GDBusConnection *bus;
static unsigned count;

struct request { GMainLoop *loop; GVariant *reply; };

static gboolean deadline(gpointer data) {
    struct request *r = data;
    g_main_loop_quit(r->loop);
    return G_SOURCE_REMOVE;
}

static void response(GDBusConnection *c G_GNUC_UNUSED, const gchar *sender G_GNUC_UNUSED,
                     const gchar *path G_GNUC_UNUSED, const gchar *iface G_GNUC_UNUSED,
                     const gchar *sig G_GNUC_UNUSED, GVariant *parameters, gpointer data) {
    struct request *r = data;
    r->reply = g_variant_ref(parameters);
    g_main_loop_quit(r->loop);
}

static GVariant *call_request(const char *iface, const char *method, const char *session) {
    gboolean create = g_str_equal(method, "CreateSession");
    gboolean select = g_str_equal(method, "SelectSources");
    gboolean file = g_str_equal(method, "OpenFile");
    g_autoptr(GError) error = NULL;
    g_autoptr(GMainLoop) loop = g_main_loop_new(NULL, FALSE);
    struct request r = {.loop = loop};
    g_autofree gchar *token = g_strdup_printf("qa_%d_%u", getpid(), ++count);
    g_autofree gchar *unique = g_strdup(g_dbus_connection_get_unique_name(bus) + 1);
    g_strdelimit(unique, ".", '_');
    g_autofree gchar *path = g_strdup_printf("/org/freedesktop/portal/desktop/request/%s/%s", unique, token);
    guint sub = g_dbus_connection_signal_subscribe(bus, desktop, "org.freedesktop.portal.Request", "Response",
                                                 path, NULL, G_DBUS_SIGNAL_FLAGS_NONE, response, &r, NULL);
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token));
    if (create) {
        g_autofree gchar *session_token = g_strconcat(token, "_session", NULL);
        g_variant_builder_add(&options, "{sv}", "session_handle_token", g_variant_new_string(session_token));
    } else if (select) {
        g_variant_builder_add(&options, "{sv}", "types", g_variant_new_uint32(1));
        g_variant_builder_add(&options, "{sv}", "cursor_mode", g_variant_new_uint32(1));
    }
    GVariant *opts = g_variant_builder_end(&options);
    GVariant *params = create ? g_variant_new("(@a{sv})", opts) :
                       select ? g_variant_new("(o@a{sv})", session, opts) :
                       file ? g_variant_new("(ss@a{sv})", "", "Kaze QA File Picker", opts) :
                              g_variant_new("(os@a{sv})", session, "", opts);
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(bus, desktop, object, iface, method, params,
                                               G_VARIANT_TYPE("(o)"), 0, 8000, NULL, &error);
    if (!reply) g_error("%s: %s", method, error->message);
    const gchar *real_path;
    g_variant_get(reply, "(&o)", &real_path);
    if (!g_str_equal(path, real_path)) g_error("Unexpected request path: %s", real_path);
    guint timer = g_timeout_add_seconds(20, deadline, &r);
    g_main_loop_run(loop);
    if (!r.reply) g_error("Awaiting response for %s timed out", method);
    g_source_remove(timer);
    g_dbus_connection_signal_unsubscribe(bus, sub);
    guint32 code;
    GVariant *results;
    g_variant_get(r.reply, "(u@a{sv})", &code, &results);
    g_variant_unref(r.reply);
    g_print("%s response=%u\n", method, code);
    if (file ? (code != 1 && code != 2) : code != 0) g_error("Unexpected response from %s", method);
    return results;
}

static gboolean receive_frames(const char *session, guint32 node) {
    g_autoptr(GError) error = NULL;
    g_autoptr(GUnixFDList) fds = NULL;
    GVariantBuilder empty;
    g_variant_builder_init(&empty, G_VARIANT_TYPE_VARDICT);
    g_autoptr(GVariant) remote = g_dbus_connection_call_with_unix_fd_list_sync(bus, desktop, object, cast, "OpenPipeWireRemote",
        g_variant_new("(oa{sv})", session, &empty), G_VARIANT_TYPE("(h)"), 0, 8000, NULL, &fds, NULL, &error);
    if (!remote || !fds) g_error("OpenPipeWireRemote: %s", error ? error->message : "no fd");
    int index;
    g_variant_get(remote, "(h)", &index);
    int fd = g_unix_fd_list_get(fds, index, &error);
    if (fd < 0) g_error("PipeWire fd: %s", error->message);
    g_autofree gchar *target = g_strdup_printf("path=%u", node);
    g_autoptr(GSubprocessLauncher) launcher = g_subprocess_launcher_new(G_SUBPROCESS_FLAGS_NONE);
    g_subprocess_launcher_take_fd(launcher, fd, 10);
    g_autoptr(GSubprocess) child = g_subprocess_launcher_spawn(launcher, &error, "timeout", "15s", "gst-launch-1.0", "-v",
        "pipewiresrc", "fd=10", target, "num-buffers=5", "!", "video/x-raw,width=1920,height=1080", "!", "fakesink", NULL);
    gboolean received = child && g_subprocess_wait_check(child, NULL, &error);
    if (!received) g_printerr("GStreamer did not consume frames: %s\n", error ? error->message : "unknown");
    return received;
}

int main(int argc, char **argv) {
    g_autoptr(GError) error = NULL;
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!bus) g_error("D-Bus: %s", error->message);
    if (argc == 2 && g_str_equal(argv[1], "file")) {
        g_variant_unref(call_request("org.freedesktop.portal.FileChooser", "OpenFile", NULL));
        g_object_unref(bus);
        return 0;
    }
    if (argc != 2 || !g_str_equal(argv[1], "cast")) g_error("Usage: portal-probe file|cast");
    g_autoptr(GVariant) created = call_request(cast, "CreateSession", NULL);
    const gchar *handle;
    if (!g_variant_lookup(created, "session_handle", "&s", &handle)) g_error("Missing session handle");
    g_variant_unref(call_request(cast, "SelectSources", handle));
    g_autoptr(GVariant) started = call_request(cast, "Start", handle);
    g_autoptr(GVariant) streams = g_variant_lookup_value(started, "streams", G_VARIANT_TYPE("a(ua{sv})"));
    if (!streams || g_variant_n_children(streams) != 1) g_error("Expected one monitor stream");
    guint32 node;
    g_autoptr(GVariant) props = NULL;
    g_variant_get_child(streams, 0, "(u@a{sv})", &node, &props);
    g_autofree gchar *details = g_variant_print(props, TRUE);
    g_print("PipeWire node=%u %s\n", node, details);
    gboolean received = receive_frames(handle, node);
    g_autoptr(GVariant) closed = g_dbus_connection_call_sync(bus, desktop, handle, "org.freedesktop.portal.Session", "Close",
        NULL, G_VARIANT_TYPE_UNIT, 0, 5000, NULL, &error);
    if (!closed) g_error("Close failed: %s", error->message);
    g_object_unref(bus);
    g_print("Portal session closed; five 1920x1080 frames: %s\n", received ? "PASS" : "FAIL");
    return received ? 0 : 1;
}
