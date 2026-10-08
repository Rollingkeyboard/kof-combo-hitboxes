# KoF Combo Hitbox Viewer

KoF Combo Hitbox Viewer is a Windows overlay for inspecting fighting-game collision boxes in supported games. It reads live game memory and draws hitboxes, hurtboxes, player pivots, and other supported data over the game window.

This fork adds support for the **64-bit Steam executable of _The King of Fighters 2002 Unlimited Match_**. The 1.0.4 x64 build is based on the upstream 1.0.3 project and retains its other supported game integrations.

## Download

Get the Windows build from the [Releases page](https://github.com/Rollingkeyboard/kof-combo-hitboxes/releases). For the Steam x64 build, download the `kof-combo-hitboxes-1.0.4-x64` archive and extract the complete folder. Keep `kof-hitboxes.exe`, `default.ini`, and the `lua` folder together.

## Quick start

1. Start a supported game and enter a match or training mode.
2. Run `kof-hitboxes.exe` from the extracted folder.
3. Read the console window for game detection, configuration, and hotkey status.
4. Keep the viewer running while playing. Press `Q` in its console window to exit.

The overlay is positioned immediately above the game in the normal window order. Other applications can cover both the game and its overlay; the overlay does not stay on top of unrelated windows. For KOF 2002 UM, the recommended game resolution is **640×448** and **Screen Type B** (`Game Options → Graphic Settings`). Other resolutions may work, but scaling can make boxes appear thicker or less crisp.

## KOF 2002 UM Steam x64

The x64 build detects the 64-bit Steam game and reads player hitbox data. The current x64 profile does **not** draw projectile hitboxes; projectile memory has not been independently mapped for this executable. Use the game's normal windowed display mode for the overlay.

If the console reports `Direct3D frame presentation failed (HRESULT -2005530520)`, the Direct3D device has been lost. Builds containing the device recovery change wait for Windows to make the device available and then attempt to restore drawing. If the overlay remains frozen, close and restart the viewer.

## Hotkeys

Hotkeys are checked while the game window, overlay, or viewer console has focus. They are not global hotkeys.

| Key | Action |
| --- | --- |
| `F1` | Toggle Player 1 close normal range marker, where supported |
| `F2` | Toggle Player 2 close normal range marker, where supported |
| `F3` | Toggle hitbox fill; box outlines remain visible |
| `F4` | Toggle hitbox center axes |
| `F5` | Toggle throwable boxes |
| `F6` | Toggle stale throw boxes |
| `F7` | Toggle gauge overlays |
| `F8` | Toggle the KOF98 keyboard input display |
| `F9` | Toggle KOF98 rhythm graph, input logging, and Shermie command practice |
| `Q` | Exit when pressed in the viewer console |

The x64 KOF 2002 UM profile supports the range markers and player hitboxes. Gauge or projectile overlays depend on game support and configuration.

For KOF98 UM Final Edition, the input display reads both players' keyboard bindings from the game's `Data\~options.bin` file when the viewer starts. It converts the saved scan codes to keyboard keys and shows a live directional pad, attack buttons, and recent input changes. Attack buttons use the KOF mapping `A=LP`, `B=LK`, `C=SP`, `D=SK`, even though the saved preset lists them as `LP/SP/LK/SK`. Press `F8` to hide or show the display. Press `F9` for the rhythm graph and input timing log; console entries report how long each input state was held. The Shermie rhythm lane remains available while Shermie is selected.

Press `F10` to enable character command validation. The viewer reads each player's current character ID from the game and loads that character's command set from the KOF98UM roster. A small, one-line message over the game shows the recognized move, the input notation, total motion time, and the longest step. The current practice target is at most **1200 ms total** and **450 ms per step**; these are configurable coach heuristics, not verified KOF98 move-input or cancel windows. Follow-up spacing is also reported as a coach measurement, not a game cancel pass/fail result. The data covers all 64 roster entries, including the separately selectable alternate characters. Straightforward directional commands and documented follow-up branches are recognized; charge inputs, air-state restrictions, multi-tap commands, and some context-dependent variants still need dedicated handling. A recognized command confirms the keyboard motion only; it does not confirm that the move came out, hit, or was in range. Directions are converted to forward/back using each character's current facing. Input capture only runs while the game window is active and waits for all mapped keys to be released after focus returns. Restart the viewer after changing keyboard bindings in the game.

## Box colors

Colors can be customized in `default.ini`. The default palette uses blue shades for vulnerable boxes, red for attack boxes, cyan for guard boxes, orange for projectile vulnerability, magenta for throw boxes, green for collision and range markers, and white for player pivots. Some box types use transparent fill and appear as outlines only. A fighter is represented by several gameplay boxes, so boxes can overlap and do not trace the character's sprite silhouette.

## Configuration

Edit `default.ini` next to the executable. The `[global]` section controls shared rendering options such as edge opacity, fill opacity, box fill, pivots, projectile drawing, and gauges. The `[player1]` and `[player2]` sections enable each player's boxes and configure supported range markers. The `[colors]` section sets box colors as RGB or RGBA values from 0 to 255.

The viewer loads `default.ini` and then a game-specific configuration file when one exists. A missing game-specific file is reported in the console; the defaults still load.

## Supported games

### Steam and GOG

- _The King of Fighters '98 Ultimate Match Final Edition_ (Steam and GOG)
- _The King of Fighters 2002 Unlimited Match_ (Steam and GOG, including Steam x64)
- _Guilty Gear XX #Reload_ (non-Steam releases are untested)
- _Guilty Gear XX Accent Core +R_

### PlayStation 2 through PCSX2

- _The King of Fighters XI_
- _The King of Fighters '98 Ultimate Match_
- _The King of Fighters 2002 Unlimited Match_ (original and Tougeki versions)
- _The King of Fighters NeoWave_
- _NeoGeo Battle Coliseum_
- _Capcom vs. SNK 2_ (NTSC-U only)
- _Capcom Fighting Evolution_ (NTSC-U only)

Support and available overlays vary by game and release. Check the viewer console at startup for the detected game and the hotkeys available for that profile.

## Requirements

- Windows Vista or newer with Desktop Window Manager (DWM) enabled.
- A supported game version listed above.
- For PS2 titles, PCSX2; the upstream project has tested PCSX2 1.4.0.

## Build from source

The Windows x64 executable is built with a 64-bit MinGW-w64 toolchain. The repository includes LuaJIT as a submodule.

```sh
git clone --recurse-submodules https://github.com/Rollingkeyboard/kof-combo-hitboxes.git
cd kof-combo-hitboxes
make lua
make
```

For Linux cross-compilation, use `x86_64-w64-mingw32-gcc` and `x86_64-w64-mingw32-ar`. On Windows, `make.bat` invokes `mingw32-make`.

## Credits

This project builds on the original [odabugs/kof-combo-hitboxes](https://github.com/odabugs/kof-combo-hitboxes) project. Thanks to PhoenixNL for testing and hitbox ID research, Jesuszilla for reverse engineering _Capcom vs. SNK 2_ and _Capcom Fighting Evolution_, and Pasky for reverse engineering _Guilty Gear XX #Reload_.

## License

See [LICENSE.txt](LICENSE.txt).
