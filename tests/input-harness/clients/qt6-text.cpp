// Qt6 Wayland text client. QLineEdit with ImhDigitsOnly; transcripts
// focus/content/keys/commits. Purpose comes from PF_TX_PURPOSE (default digits).
#include <QApplication>
#include <QLineEdit>
#include <QTimer>
#include <QShowEvent>
#include <QVBoxLayout>
#include <QFocusEvent>
#include <QKeyEvent>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <string>

extern "C" {
#include "../tools/transcript.h"
}

static std::string g_prev_text;
static QLineEdit *g_edit;

static const char *purpose_name()
{
	const char *p = getenv("PF_TX_PURPOSE");
	if (!p || !*p)
		p = "digits";
	return p;
}

class Watch : public QObject
{
public:
	bool eventFilter(QObject *obj, QEvent *ev) override
	{
		if (obj == g_edit) {
			if (ev->type() == QEvent::FocusIn) {
				pf_tx_emitf("enter", ",\"serial\":0");
				pf_tx_emitf("content",
					    ",\"source\":\"set\",\"hints\":[\"none\"],\"purpose\":\"%s\"",
					    purpose_name());
				/* text-input-v3 availability is recorded
				 * truthfully by the preload interposer. */
			} else if (ev->type() == QEvent::FocusOut) {
				pf_tx_emitf("leave", ",\"serial\":0");
			} else if (ev->type() == QEvent::KeyPress ||
				   ev->type() == QEvent::KeyRelease) {
				auto *ke = static_cast<QKeyEvent *>(ev);
				char jk[64];
				pf_tx_jstr(jk, sizeof jk,
					   ke->key() ? qPrintable(ke->text()) : "");
				pf_tx_emitf("key",
					    ",\"keycode\":%u,\"keysym\":%s,\"state\":\"%s\",\"mods\":%u",
					    (unsigned)ke->nativeScanCode(), jk,
					    ev->type() == QEvent::KeyPress ? "pressed" : "released",
					    (unsigned)ke->modifiers().toInt());
			}
		}
		return QObject::eventFilter(obj, ev);
	}
};

class MappedEdit : public QLineEdit
{
public:
	explicit MappedEdit(QWidget *parent = nullptr) : QLineEdit(parent) {}
protected:
	void showEvent(QShowEvent *ev) override
	{
		QLineEdit::showEvent(ev);
		pf_tx_emitf("mapped", ",\"width\":%d,\"height\":%d",
			    width(), height());
	}
};

static void on_text_edited(const QString &text)
{
	std::string cur = text.toStdString();
	std::string ins;
	if (cur.size() > g_prev_text.size() &&
	    cur.compare(0, g_prev_text.size(), g_prev_text) == 0)
		ins = cur.substr(g_prev_text.size());
	else
		ins = cur;
	g_prev_text = cur;
	if (ins.empty())
		return;
	char j[512];
	pf_tx_jstr(j, sizeof j, ins.c_str());
	pf_tx_emitf("commit", ",\"text\":%s,\"source\":\"toolkit\"", j);
}

static void on_sigterm(int)
{
	pf_tx_stop(0);
	_exit(0);
}

int main(int argc, char **argv)
{
	if (pf_tx_begin("qt6-text", "wayland", getenv("WAYLAND_DISPLAY"),
			argc, argv) != 0)
		return 1;
	signal(SIGTERM, on_sigterm);

	QApplication app(argc, argv);
	QWidget win;
	win.setWindowTitle("pf-input-harness qt6-text");
	win.resize(640, 480);
	auto *layout = new QVBoxLayout(&win);
	g_edit = new MappedEdit(&win);
	g_edit->setInputMethodHints(Qt::ImhDigitsOnly);
	g_edit->setPlaceholderText("type digits");
	layout->addStretch(1);
	layout->addWidget(g_edit);
	layout->addStretch(1);
	win.show();
	g_edit->setFocus();

	auto *watch = new Watch();
	g_edit->installEventFilter(watch);
	QObject::connect(g_edit, &QLineEdit::textEdited, on_text_edited);

	QTimer::singleShot(120000, [] {
		pf_tx_stop(0);
		exit(0);
	});
	int rc = app.exec();
	pf_tx_stop(0);
	return rc;
}

