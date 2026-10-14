/* GTK3-on-X11 text client ('X11 apps with GTK/Qt' row). Runs under Xwayland
 * via GDK_BACKEND=x11. Commits are guaranteed through im-context-simple.
 */
#define _GNU_SOURCE
#include "../tools/transcript.h"

#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>


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

static gboolean on_focus_in(GtkWidget *w, GdkEvent *ev, gpointer data)
{
	(void)w; (void)ev;
	/* GdkEventFocus carries no protocol serial; the schema allows 0. */
	pf_tx_emitf("enter", ",\"serial\":0");
	pf_tx_emitf("content",
		    ",\"source\":\"set\",\"hints\":[\"none\"],\"purpose\":\"%s\"",
		    data ? (char *)data : "url");
	return FALSE;
}

static gboolean on_focus_out(GtkWidget *w, GdkEvent *ev, gpointer data)
{
	(void)w; (void)ev; (void)data;
	pf_tx_emitf("leave", ",\"serial\":0");
	return FALSE;
}

static gboolean on_key_press(GtkWidget *w, GdkEvent *ev, gpointer data)
{
	(void)w; (void)data;
	char j[64];
	pf_tx_jstr(j, sizeof j, gdk_keyval_name(ev->key.keyval));
	pf_tx_emitf("key",
		    ",\"keycode\":%u,\"keysym\":%s,\"state\":\"pressed\",\"mods\":%u",
		    ev->key.hardware_keycode, j, (unsigned)ev->key.state);
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

static void on_changed(GtkEditable *ed, gpointer data)
{
	(void)data;
	const char *text = gtk_entry_get_text(GTK_ENTRY(ed));
	char j[512];
	pf_tx_jstr(j, sizeof j, text);
	pf_tx_emitf("widget_text", ",\"text\":%s", j);
}

static void on_map(GtkWidget *w, gpointer data)
{
	(void)data;
	GtkAllocation alloc;
	gtk_widget_get_allocation(w, &alloc);
	pf_tx_emitf("mapped", ",\"width\":%d,\"height\":%d", alloc.width,
		    alloc.height);
}

static gboolean watchdog(gpointer data)
{
	(void)data;
	pf_tx_stop(0);
	exit(0);
	return G_SOURCE_REMOVE;
}

int main(int argc, char **argv)
{
	if (pf_tx_begin("x11-gtk", "x11", getenv("DISPLAY"), argc, argv) != 0)
		return 1;
	pf_tx_arm_sigterm();

	gtk_init(&argc, &argv);

	/* No XIM server runs in the harness session and the driver forces
	 * GTK_IM_MODULE=simple, so GTK commits locally through
	 * im-context-simple; record that no wire IM protocol is in play. */
	pf_tx_emitf("im_state",
		    ",\"protocol\":\"none\",\"state\":\"unavailable\"");

	const char *purpose = getenv("PF_TX_PURPOSE");
	if (!purpose || !*purpose)
		purpose = "url";

	GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
	gtk_window_set_default_size(GTK_WINDOW(win), 640, 480);
	gtk_window_set_title(GTK_WINDOW(win), "pf-input-harness x11-gtk");
	GtkWidget *entry = gtk_entry_new();
	gtk_entry_set_input_purpose(GTK_ENTRY(entry), parse_purpose(purpose));
	gtk_container_add(GTK_CONTAINER(win), entry);

	g_signal_connect(entry, "focus-in-event", G_CALLBACK(on_focus_in),
			 (gpointer)purpose);
	g_signal_connect(entry, "focus-out-event", G_CALLBACK(on_focus_out),
			 NULL);
	g_signal_connect(entry, "key-press-event", G_CALLBACK(on_key_press),
			 NULL);
	g_signal_connect(entry, "insert-text", G_CALLBACK(on_insert_text),
			 NULL);
	g_signal_connect(entry, "changed", G_CALLBACK(on_changed), NULL);
	g_signal_connect(win, "map", G_CALLBACK(on_map), NULL);
	g_signal_connect(win, "destroy", G_CALLBACK(gtk_main_quit), NULL);

	gtk_widget_show_all(win);
	gtk_widget_grab_focus(entry);
	g_timeout_add_seconds(120, watchdog, NULL);
	gtk_main();
	pf_tx_stop(0);
	return 0;
}
