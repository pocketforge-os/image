/* SDL3 native-Wayland text client. SDL_StartTextInput path; transcripts
 * keys/commits/focus/pointer/screen-keyboard.
 */
#define _GNU_SOURCE
#include "../tools/transcript.h"

#include <SDL3/SDL.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

static int map_button(Uint8 b)
{
	switch (b) {
	case SDL_BUTTON_LEFT: return 272;
	case SDL_BUTTON_RIGHT: return 273;
	case SDL_BUTTON_MIDDLE: return 274;
	default: return 272 + (int)b - 1;
	}
}

int main(int argc, char **argv)
{
	if (pf_tx_begin("sdl3-text", "wayland", getenv("WAYLAND_DISPLAY"),
			argc, argv) != 0)
		return 1;
	pf_tx_arm_sigterm();

	if (!SDL_Init(SDL_INIT_VIDEO)) {
		pf_tx_emitf("error", ",\"message\":\"SDL_Init: %s\"",
			    SDL_GetError());
		pf_tx_stop(1);
		return 1;
	}
	SDL_Window *win = SDL_CreateWindow("pf-input-harness sdl3-text", 640,
					   480, 0);
	if (!win) {
		pf_tx_emitf("error", ",\"message\":\"SDL_CreateWindow: %s\"",
			    SDL_GetError());
		pf_tx_stop(1);
		return 1;
	}
	SDL_StartTextInput(win);
	pf_tx_emitf("im_state",
		    ",\"protocol\":\"sdl-textinput\",\"state\":\"enabled\"");
	const char *purpose = getenv("PF_TX_PURPOSE");
	if (!purpose || !*purpose)
		purpose = "normal";
	pf_tx_emitf("content",
		    ",\"source\":\"set\",\"hints\":[\"none\"],\"purpose\":\"%s\"",
		    purpose);

	SDL_Event ev;
	bool last_shown = false;
	Uint64 deadline = SDL_GetTicks() + 120000;
	while (SDL_GetTicks() < deadline) {
		if (!SDL_WaitEventTimeout(&ev, 200)) {
			bool shown = SDL_ScreenKeyboardShown(win);
			if (shown != last_shown) {
				last_shown = shown;
				pf_tx_emitf("screen_keyboard",
					    ",\"shown\":%s",
					    shown ? "true" : "false");
			}
			continue;
		}
		switch (ev.type) {
		case SDL_EVENT_WINDOW_EXPOSED:
		case SDL_EVENT_WINDOW_SHOWN: {
			int w = 0, h = 0;
			SDL_GetWindowSize(win, &w, &h);
			pf_tx_emitf("mapped", ",\"width\":%d,\"height\":%d", w,
				    h);
			break;
		}
		case SDL_EVENT_WINDOW_FOCUS_GAINED:
			pf_tx_emitf("enter", ",\"serial\":0");
			break;
		case SDL_EVENT_WINDOW_FOCUS_LOST:
			pf_tx_emitf("leave", ",\"serial\":0");
			break;
		case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
			goto done;
		case SDL_EVENT_KEY_DOWN:
		case SDL_EVENT_KEY_UP: {
			const char *name = SDL_GetKeyName(ev.key.key);
			char j[64];
			pf_tx_jstr(j, sizeof j, name ? name : "");
			pf_tx_emitf("key",
				    ",\"keycode\":%d,\"keysym\":%s,\"state\":\"%s\",\"mods\":%u",
				    (int)ev.key.scancode, j,
				    ev.type == SDL_EVENT_KEY_DOWN ? "pressed"
								  : "released",
				    (unsigned)ev.key.mod);
			break;
		}
		case SDL_EVENT_TEXT_INPUT: {
			char j[256];
			pf_tx_jstr(j, sizeof j, ev.text.text);
			pf_tx_emitf("commit",
				    ",\"text\":%s,\"source\":\"toolkit\"", j);
			break;
		}
		case SDL_EVENT_MOUSE_MOTION:
			pf_tx_emitf("pointer_motion", ",\"x\":%.1f,\"y\":%.1f",
				    ev.motion.x, ev.motion.y);
			break;
		case SDL_EVENT_MOUSE_BUTTON_DOWN:
		case SDL_EVENT_MOUSE_BUTTON_UP:
			pf_tx_emitf("pointer_button",
				    ",\"button\":%d,\"state\":\"%s\",\"x\":%.1f,\"y\":%.1f",
				    map_button(ev.button.button),
				    ev.type == SDL_EVENT_MOUSE_BUTTON_DOWN
					    ? "pressed"
					    : "released",
				    ev.button.x, ev.button.y);
			break;
		case SDL_EVENT_MOUSE_WHEEL:
			pf_tx_emitf("pointer_axis",
				    ",\"axis\":\"vertical\",\"value\":%.1f",
				    ev.wheel.y);
			break;
		case SDL_EVENT_QUIT:
			goto done;
		default:
			break;
		}
	}
done:
	SDL_DestroyWindow(win);
	SDL_Quit();
	pf_tx_stop(0);
	return 0;
}
