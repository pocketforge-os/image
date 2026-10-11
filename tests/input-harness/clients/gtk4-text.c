/* GTK4 Wayland text client. Transcripts focus/content/keys/commits/pointer.
 * Content purpose comes from PF_TX_PURPOSE (default "email").
 */
#define _GNU_SOURCE
#include "../tools/transcript.h"

#include <gtk/gtk.h>
#include <string.h>

static GtkWidget *g_entry;
static const char *g_purpose;

static GtkInputPurpose parse_purpose(const char *s)
{
	if (!strcmp(s, "alpha")) return GTK_INPUT_PURPOSE_ALPHA;
	if (!strcmp(s, "digits") || !strcmp(s, "number")) return GTK_INPUT_PURPOSE_DIGITS;
	if (!strcmp(s, "phone")) return GTK_INPUT_PURPOSE_PHONE;
	if (!strcmp(s, "url")) return GTK_INPUT_PURPOSE_URL;
	if (!strcmp(s, "email")) return GTK_INPUT_PURPOSE_EMAIL;
	if (!strcmp(s, "password") || !strcmp(s, "pin")) return GTK_INPUT_PURPOSE_PASSWORD;
	if (!strcmp(s, "terminal")) return GTK_INPUT_PURPOSE_TERMINAL;
	return GTK_INPUT_PURPOSE_FREE_FORM;
}

static void on_focus_enter(GtkEventControllerFocus *c, gpointer data)
{
	(void)c; (void)data;
	pf_tx_emitf("enter", ",\"serial\":0");
	pf_tx_emitf("content",
		    ",\"source\":\"set\",\"hints\":[\"none\"],\"purpose\":\"%s\"",
		    g_purpose);
	/* text-input-v3 availability is recorded truthfully by the preload
	 * interposer (im_state); the client must not claim wire state. */
}

static void on_focus_leave(GtkEventControllerFocus *c, gpointer data)
{
	(void)c; (void)data;
	pf_tx_emitf("leave", ",\"serial\":0");
}

static gboolean on_key_pressed(GtkEventControllerKey *c, guint keyval,
			       guint keycode, GdkModifierType state,
			       gpointer data)
{
	(void)c; (void)data;
	char jk[64];
	pf_tx_jstr(jk, sizeof jk, gdk_keyval_name(keyval));
	pf_tx_emitf("key",
		    ",\"keycode\":%u,\"keysym\":%s,\"state\":\"pressed\",\"mods\":%u",
		    keycode, jk, (unsigned)state);
	return FALSE;
}

static void on_insert_text(GtkEditable *ed, const gchar *text, gint pos,
			   gpointer data)
{
	(void)ed; (void)pos; (void)data;
	char j[256];
	pf_tx_jstr(j, sizeof j, text);
	pf_tx_emitf("commit", ",\"text\":%s,\"source\":\"toolkit\"", j);
}

static void on_button_pressed(GtkGestureClick *gc, gint n, double x, double y,
			      gpointer data)
{
	(void)gc; (void)n; (void)data;
	pf_tx_emitf("pointer_button",
		    ",\"button\":272,\"state\":\"pressed\",\"x\":%.1f,\"y\":%.1f",
		    x, y);
}

static void on_button_released(GtkGestureClick *gc, gint n, double x, double y,
			       gpointer data)
{
	(void)gc; (void)n; (void)data;
	pf_tx_emitf("pointer_button",
		    ",\"button\":272,\"state\":\"released\",\"x\":%.1f,\"y\":%.1f",
		    x, y);
}

static void on_motion(GtkEventControllerMotion *c, double x, double y,
		      gpointer data)
{
	(void)c; (void)data;
	pf_tx_emitf("pointer_motion", ",\"x\":%.1f,\"y\":%.1f", x, y);
}

static void on_map(GtkWidget *w, gpointer data)
{
	(void)data;
	int width = gtk_widget_get_width(w);
	int height = gtk_widget_get_height(w);
	pf_tx_emitf("mapped", ",\"width\":%d,\"height\":%d", width, height);
}

static gboolean watchdog(gpointer data)
{
	(void)data;
	pf_tx_stop(0);
	exit(0);
	return G_SOURCE_REMOVE;
}

static void activate(GtkApplication *app, gpointer data)
{
	(void)data;
	GtkWidget *win = gtk_application_window_new(app);
	gtk_window_set_default_size(GTK_WINDOW(win), 640, 480);
	gtk_window_set_title(GTK_WINDOW(win), "pf-input-harness gtk4-text");

	g_entry = gtk_entry_new();
	gtk_entry_set_input_purpose(GTK_ENTRY(g_entry), parse_purpose(g_purpose));
	gtk_entry_set_input_hints(GTK_ENTRY(g_entry), GTK_INPUT_HINT_NONE);
	gtk_widget_set_hexpand(g_entry, TRUE);
	gtk_widget_set_valign(g_entry, GTK_ALIGN_CENTER);
	gtk_window_set_child(GTK_WINDOW(win), g_entry);

	GtkEventController *fc = gtk_event_controller_focus_new();
	g_signal_connect(fc, "enter", G_CALLBACK(on_focus_enter), NULL);
	g_signal_connect(fc, "leave", G_CALLBACK(on_focus_leave), NULL);
	gtk_widget_add_controller(g_entry, fc);

	GtkEventController *kc = gtk_event_controller_key_new();
	g_signal_connect(kc, "key-pressed", G_CALLBACK(on_key_pressed), NULL);
	gtk_widget_add_controller(g_entry, kc);
	g_signal_connect(g_entry, "insert-text", G_CALLBACK(on_insert_text), NULL);

	GtkGesture *click = GTK_GESTURE(gtk_gesture_click_new());
	g_signal_connect(click, "pressed", G_CALLBACK(on_button_pressed), NULL);
	g_signal_connect(click, "released", G_CALLBACK(on_button_released), NULL);
	gtk_widget_add_controller(win, GTK_EVENT_CONTROLLER(click));

	GtkEventController *mc = gtk_event_controller_motion_new();
	g_signal_connect(mc, "motion", G_CALLBACK(on_motion), NULL);
	gtk_widget_add_controller(win, mc);

	g_signal_connect(win, "map", G_CALLBACK(on_map), NULL);
	gtk_window_present(GTK_WINDOW(win));
	gtk_widget_grab_focus(g_entry);
	g_timeout_add_seconds(120, watchdog, NULL);
}

int main(int argc, char **argv)
{
	g_purpose = getenv("PF_TX_PURPOSE");
	if (!g_purpose || !*g_purpose)
		g_purpose = "email";
	if (pf_tx_begin("gtk4-text", "wayland", getenv("WAYLAND_DISPLAY"),
			argc, argv) != 0)
		return 1;
	pf_tx_arm_sigterm();
	/* The harness container has no session D-Bus; NON_UNIQUE keeps
	 * GtkApplication from trying to register a bus name. */
	GtkApplication *app = gtk_application_new("org.pocketforge.harness.gtk4text",
						  G_APPLICATION_NON_UNIQUE);
	g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
	int rc = g_application_run(G_APPLICATION(app), argc, argv);
	pf_tx_stop(0);
	g_object_unref(app);
	return rc == 0 ? 0 : rc;
}
