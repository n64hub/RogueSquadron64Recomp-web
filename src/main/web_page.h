#pragma once

// The game as a page (web/page.cmake): what main() does differently there.
#ifdef __EMSCRIPTEN__

#include <string>

namespace rs64::web {

// Makes HOME, which the page keeps in the browser's storage, the working directory, where the game keeps its settings,
// saves, ROM and mods folder as it keeps them beside the program on the desktop, and copies the mods the page ships
// (its .data's /web-mods) into that mods folder.
void enter_home();

// The page's launcher, over the canvas: Load ROM, and once a ROM is kept, Start Game. Waits until the player chooses:
// 1 Start Game, 2 a ROM picked and written to <folder>/rom. <message> is a line under the buttons (why the last ROM
// was turned away), or empty.
int launcher(bool have_rom, const std::string& message, const std::string& folder);

}

#endif
