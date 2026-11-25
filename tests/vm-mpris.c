// Verification-only MPRIS player; gives Waybar a repeatable live media label.
#include <gio/gio.h>

static const char xml[] =
    "<node><interface name='org.mpris.MediaPlayer2'>"
    "<property name='Identity' type='s' access='read'/></interface>"
    "<interface name='org.mpris.MediaPlayer2.Player'>"
    "<property name='PlaybackStatus' type='s' access='read'/>"
    "<property name='Metadata' type='a{sv}' access='read'/></interface></node>";

static GVariant *get(GDBusConnection *bus G_GNUC_UNUSED, const gchar *sender G_GNUC_UNUSED,
                     const gchar *path G_GNUC_UNUSED, const gchar *iface G_GNUC_UNUSED,
                     const gchar *name, GError **error G_GNUC_UNUSED, gpointer data G_GNUC_UNUSED) {
    if (g_str_equal(name, "Identity")) return g_variant_new_string("Kaze QA");
    if (g_str_equal(name, "PlaybackStatus")) return g_variant_new_string("Playing");
    GVariantBuilder tags;
    g_variant_builder_init(&tags, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&tags, "{sv}", "xesam:title", g_variant_new_string("Geometry Test"));
    const char *artists[] = {"Kaze QA", NULL};
    g_variant_builder_add(&tags, "{sv}", "xesam:artist", g_variant_new_strv(artists, -1));
    return g_variant_builder_end(&tags);
}

int main(void) {
    GError *error = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!bus) g_error("MPRIS fixture: %s", error->message);
    GDBusNodeInfo *node = g_dbus_node_info_new_for_xml(xml, &error);
    if (!node) g_error("MPRIS fixture: %s", error->message);
    static const GDBusInterfaceVTable vtable = {.get_property = get};
    for (int i = 0; node->interfaces[i]; ++i)
        if (!g_dbus_connection_register_object(bus, "/org/mpris/MediaPlayer2", node->interfaces[i],
                                               &vtable, NULL, NULL, &error))
            g_error("MPRIS fixture: %s", error->message);
    g_bus_own_name_on_connection(bus, "org.mpris.MediaPlayer2.kaze_qa", 0, NULL, NULL, NULL, NULL);
    g_main_loop_run(g_main_loop_new(NULL, FALSE));
    return 0;
}
