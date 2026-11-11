#include "main/web_page.h"

#ifdef __EMSCRIPTEN__

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <emscripten.h>
#include <emscripten/threading.h>

namespace rs64::web {

void enter_home()
{

    const char* home = std::getenv("HOME");

    if (!home || !*home)
    {
        return;
    }

    std::error_code ec;
    std::filesystem::create_directories(home, ec);
    std::filesystem::current_path(home, ec);

    // The page's mods replace what an older page left of them; a mod the player added stays.
    const auto options = std::filesystem::copy_options::recursive | std::filesystem::copy_options::overwrite_existing;
    std::filesystem::copy("/web-mods", std::filesystem::path(home) / "mods", options, ec);

    fprintf(stderr, "[main] page: data in %s%s\n", home, ec ? " (the page's mods not copied)" : "");
}

// A browser has no message boxes or file dialogs for a program, and it keeps a page silent until the player clicks or
// presses a key, so the game always starts from these buttons. Shown on the page's thread; the choice comes back in
// *state. A browser opens its file picker only from a click the player has just made, so it opens in the click's own
// handler. The buttons are hit-tested on the window's mouse events, so a click dispatched on the canvas by a script
// reaches them as a player's does, and Enter is Start Game.
EM_JS(void, rs64_web_launcher, (int have_rom, const char* message_ptr, const char* folder_ptr, int32_t* state_ptr), {
    const message = UTF8ToString(message_ptr), folder = UTF8ToString(folder_ptr), state = state_ptr >> 2;
    let panel = document.getElementById('rs64-launcher');
    if (panel) panel.remove();
    panel = document.createElement('div');
    panel.id = 'rs64-launcher';
    panel.style.cssText = 'position:fixed;inset:0;z-index:900;background:#0b0f1a;color:#eee;font:16px sans-serif';
    const place = (element, dy) => {
        element.style.cssText += ';position:absolute;left:50%;top:calc(50% + ' + dy + 'px);transform:translate(-50%,-50%)';
        panel.appendChild(element);
        return element;
    };
    const title = place(document.createElement('div'), -90);
    title.textContent = 'Star Wars: Rogue Squadron';
    title.style.cssText += ';font-size:32px;font-weight:bold;white-space:nowrap';
    const button = (text, dy) => {
        const b = place(document.createElement('button'), dy);
        b.textContent = text;
        b.style.cssText += ';font-size:20px;padding:10px 28px;min-width:220px;cursor:pointer';
        return b;
    };
    const primary = button(have_rom ? 'Start Game' : 'Load ROM', 0);
    const other = have_rom ? button('Load another ROM', 64) : null;
    const note = place(document.createElement('div'), have_rom ? 124 : 70);
    note.textContent = message || 'Your own dump of the US cartridge, v1.0 (.z64, .n64 or .v64). It stays in this browser.';
    note.style.cssText += ';font-size:14px;color:#bbb;width:90%;max-width:640px;text-align:center;white-space:pre-line';

    let done = false;
    const finish = (result) => {
        if (done) return;
        done = true;
        removeEventListener('mouseup', onMouse, true);
        removeEventListener('keydown', onKey, true);
        panel.remove();
        Atomics.store(HEAP32, state, result);
        Atomics.notify(HEAP32, state);
    };
    const pick = () => {
        const input = document.createElement('input');
        input.type = 'file';
        input.accept = '.z64,.n64,.v64';
        input.addEventListener('change', async () => {
            const file = input.files[0];
            if (!file) return;
            note.textContent = 'Reading ' + file.name + '…';
            FS.mkdirTree(folder);
            FS.writeFile(folder + '/rom', new Uint8Array(await file.arrayBuffer()));
            finish(2);
        });
        // Held until it is answered: Chrome holds an open picker's input only weakly.
        panel.rs64Input = input;
        input.click();
    };
    const inside = (element, event) => {
        if (!element) return false;
        const r = element.getBoundingClientRect();
        return event.clientX >= r.left && event.clientX < r.right && event.clientY >= r.top && event.clientY < r.bottom;
    };
    const onMouse = (event) => {
        if (inside(primary, event)) {
            have_rom ? finish(1) : pick();
        } else if (inside(other, event)) {
            pick();
        }
    };
    const onKey = (event) => {
        if (have_rom && event.key === 'Enter') {
            event.preventDefault();
            finish(1);
        }
    };
    addEventListener('mouseup', onMouse, true);
    addEventListener('keydown', onKey, true);
    document.body.appendChild(panel);
    const status = document.getElementById('status');
    if (status) status.hidden = true;
});

int launcher(bool have_rom, const std::string& message, const std::string& folder)
{

    std::atomic<int32_t> state{0};
    emscripten_async_run_in_main_runtime_thread(EM_FUNC_SIG_VIIII, rs64_web_launcher, int(have_rom), message.c_str(),
                                                folder.c_str(), reinterpret_cast<int32_t*>(&state));

    while (state.load() == 0) {
        emscripten_futex_wait(&state, 0, INFINITY);
    }

    return state.load();
}

}

#endif
