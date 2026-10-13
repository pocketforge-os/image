/* SDL2 (sdl2-compat) game client. Stands in for the 'SDL2 game through
 * sdl2-compat' row: StartTextInput, TEXTINPUT commits, keys, focus,
 * screen-keyboard visibility.
 */
#define _GNU_SOURCE
#include "../tools/transcript.h"

#include <SDL.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
	if (pf_tx_begin("sdl2-game", "wayland", getenv("WAYLAND_DISPLAY"),
			argc, argv) != 0)
		return 1;
	pf_tx_arm_sigterm();

	if (SDL_Init(SDL_INIT_VIDEO) != 0) {
		pf_tx_emitf("error", ",\"message\":\"SDL_Init: %s\"",
			    SDL_GetError());
		pf_tx_stop(1);
		return 1;
	}
	SDL_Window *win =
		SDL_CreateWindow("pf-input-harness sdl2-game",
				 SDL_WINDOWPOS_UNDEFINED,
				 SDL_WINDOWPOS_UNDEFINED, 640, 480, 0);
	if (!win) {
		pf_tx_emitf("error", ",\"message\":\"SDL_CreateWindow: %s\"",
			    SDL_GetError());
		pf_tx_stop(1);
		return 1;
	}
	SDL_Renderer *renderer =
		SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
	if (!renderer) {
		pf_tx_emitf("error", ",\"message\":\"SDL_CreateRenderer: %s\"",
			    SDL_GetError());
		SDL_DestroyWindow(win);
		SDL_Quit();
		pf_tx_stop(1);
		return 1;
	}
	SDL_SetRenderDrawColor(renderer, 48, 64, 80, 255);
	SDL_RenderClear(renderer);
	SDL_RenderPresent(renderer);
	SDL_StartTextInput();
	pf_tx_emitf("im_state",
		    ",\"protocol\":\"sdl-textinput\",\"state\":\"enabled\"");

	int kb_shown = -1;
	SDL_Event ev;
	Uint32 deadline = SDL_GetTicks() + 120000;
	while (SDL_GetTicks() < deadline) {
		while (SDL_PollEvent(&ev)) {
			switch (ev.type) {
			case SDL_WINDOWEVENT:
				if (ev.window.event ==
				    SDL_WINDOWEVENT_EXPOSED) {
					int w = 0, h = 0;
					SDL_GetWindowSize(win, &w, &h);
					pf_tx_emitf("mapped",
						    ",\"width\":%d,\"height\":%d",
						    w, h);
				} else if (ev.window.event ==
					   SDL_WINDOWEVENT_FOCUS_GAINED) {
					pf_tx_emitf("enter", ",\"serial\":0");
				} else if (ev.window.event ==
					   SDL_WINDOWEVENT_FOCUS_LOST) {
					pf_tx_emitf("leave", ",\"serial\":0");
				} else if (ev.window.event ==
					   SDL_WINDOWEVENT_CLOSE) {
					goto done;
				}
				break;
			case SDL_KEYDOWN:
			case SDL_KEYUP: {
				const char *name =
					SDL_GetKeyName(ev.key.keysym.sym);
				char j[64];
				pf_tx_jstr(j, sizeof j, name ? name : "");
				pf_tx_emitf("key",
					    ",\"keycode\":%d,\"keysym\":%s,\"state\":\"%s\",\"mods\":%u",
					    (int)ev.key.keysym.scancode, j,
					    ev.type == SDL_KEYDOWN ? "pressed"
								   : "released",
					    (unsigned)ev.key.keysym.mod);
				break;
			}
			case SDL_TEXTINPUT: {
				char j[256];
				pf_tx_jstr(j, sizeof j, ev.text.text);
				pf_tx_emitf("commit",
					    ",\"text\":%s,\"source\":\"toolkit\"",
					    j);
				break;
			}
			case SDL_MOUSEMOTION:
				pf_tx_emitf("pointer_motion",
					    ",\"x\":%.1f,\"y\":%.1f",
					    (double)ev.motion.x,
					    (double)ev.motion.y);
				break;
			case SDL_MOUSEBUTTONDOWN:
			case SDL_MOUSEBUTTONUP: {
				int btn = ev.button.button == SDL_BUTTON_LEFT
						  ? 272
					  : ev.button.button == SDL_BUTTON_RIGHT
						  ? 273
						  : 274;
				pf_tx_emitf("pointer_button",
					    ",\"button\":%d,\"state\":\"%s\",\"x\":%.1f,\"y\":%.1f",
					    btn,
					    ev.type == SDL_MOUSEBUTTONDOWN
						    ? "pressed"
						    : "released",
					    (double)ev.button.x,
					    (double)ev.button.y);
				break;
			}
			case SDL_MOUSEWHEEL:
				pf_tx_emitf("pointer_axis",
					    ",\"axis\":\"vertical\",\"value\":%d",
					    ev.wheel.y);
				break;
			case SDL_QUIT:
				goto done;
			default:
				break;
			}
		}
		int shown = SDL_IsScreenKeyboardShown(win) ? 1 : 0;
		if (shown != kb_shown) {
			kb_shown = shown;
			pf_tx_emitf("screen_keyboard", ",\"shown\":%s",
				    shown ? "true" : "false");
		}
		SDL_Delay(10);
	}
done:
	SDL_StopTextInput();
	SDL_DestroyRenderer(renderer);
	SDL_DestroyWindow(win);
	SDL_Quit();
	pf_tx_stop(0);
	return 0;
}
