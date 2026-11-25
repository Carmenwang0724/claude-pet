# ClaudePet

A desktop pet for macOS that keeps an eye on your Claude Code sessions.

She wanders around the screen, hops onto windows, climbs the screen edges, plays with the mouse, and now and then runs off with a few of your desktop icons. Above her head floats a small task list that shows which Claude sessions are still running, which are waiting for you, and which are done.

The app is a small Swift/AppKit program. It works with any pet in the Petdex (Codex pet) spritesheet format. No artwork is included in this repository.

中文说明见 [README.zh-CN.md](README.zh-CN.md)。

## What she does

- Stands around most of the time. Now and then she walks a little, hops, or strikes one of the spare poses in the spritesheet.
- Jumps onto the top edge of a window when there is room for her, and rides along when you move that window.
- Walks to a side of the screen and climbs it. At the top she may cross over and walk upside down under the menu bar, then let go.
- Walks over and waves when the mouse cursor comes to rest near her. Jumps away when the cursor rushes at her. Enjoys it when you rub the cursor back and forth over her head.
- Falls asleep after the computer has been idle for 5 minutes, and wakes up when you come back.
- Reminds you to take a break after 50 minutes of unbroken work, and suggests going to bed between midnight and 5 am.
- Enters the screen in a different way each time she is started.

## Task list

Every Claude session that has something going on gets one row above her head.

| Dot | Status | Meaning | Goes away when |
| --- | --- | --- | --- |
| Orange | Needs approval, Needs input | Claude is stuck on a permission prompt or a question | you answer it |
| Red | Blocked | the turn ended with an error | you click the row, or send a new message in that session |
| Green | Ready | the turn finished and you have not looked yet | same as above |
| Blue | Running | still working | it finishes, fails, or you interrupt it |

- Rows are ordered by urgency: waiting for you first, then failed, finished, running.
- Each row shows the session title and how long it has been in that state. Titles are the ones the Claude desktop app shows.
- Clicking a row brings Claude to the front and opens that session. This uses the `claude://` link of the Claude desktop app, so it only opens the exact session for sessions started there.
- Up to 5 rows are shown. The rest are folded into a "+N more" row.
- Claude sends no event when you interrupt a turn. The pet notices by reading the end of the session transcript, which takes 5 to 10 seconds.
- The list always rides above her head. Click the short line in its top right corner to collapse it into a small badge such as "3 unread · 1 running", whose dot takes the colour of the most urgent session. Click the badge to open the list again. The choice is remembered.

How she reacts to Claude:

| Claude | Pet |
| --- | --- |
| starts working | opens her book for a few seconds |
| waits for a permission or an answer | comes down from the wall or wakes up, stands still, waves every 6 seconds |
| finishes a turn | hops, then holds the review pose for 40 seconds |
| fails a turn | falls over |

## Desktop trips

She can run across the desktop, pick up a few icons one by one, carry each above her head and put it down somewhere else. A few minutes later she comes back, runs to every icon she moved and puts it back.

- **Mess Up the Desktop** in the menu moves 6 icons. With **Visit the Desktop on Her Own** switched on, she goes by herself every 15 to 30 minutes and moves 4, as long as you are at the computer to watch.
- **Tidy the Desktop** sends her out to bring the icons back. She also does this on her own 4 to 8 minutes after every mess. If you are away or she is asleep by then, she puts everything back in one go instead.
- While she carries an icon, the real Finder icon follows her, updated up to 20 times a second. These moves are sent from a background queue, so a slow answer from Finder never makes her stutter. Where a window hides the desktop she shows a copy of the icon with its file name, so you can still see what she is holding.
- A trip ends early when Claude needs you, when you pick her up with the mouse, or after 150 seconds. A tidy-up that is cut short still puts every icon back.

What it does to your files: nothing but their position on the desktop. No file is moved, renamed, opened or deleted.

Things worth knowing:

- macOS asks once whether ClaudePet may control Finder. You can take that back in System Settings > Privacy & Security > Automation.
- The layout is saved to `~/.claude-pet/desktop-snapshot.json` before the first icon moves. If it cannot be saved, she leaves the desktop alone.
- Finder only reports a position for icons that have been placed by hand or by a script. For icons that Finder lays out itself it reports nothing, so she cannot tell where they are drawn. She runs to a spot among the icons instead, and the icon jumps into her hands. Icons with a position of their own are fetched from exactly where they are. When she tidies up, icons that Finder laid out are handed back to Finder's own layout.
- A sorted desktop keeps its icons locked in place, so she turns the sorting off first. Finder's scripting can switch back the orders it knows (name, kind, size, tags, date modified, date created). Other orders, such as Date Added, have to be re-selected by hand from the desktop's right-click menu. In that case a request from the menu asks you first, and she never starts such a trip on her own.

## Mouse and menu

- Click her: opens the session that needs you most, or just brings Claude forward. She also hops onto the Claude window.
- Drag her: carry her somewhere else. Let go while moving and she gets thrown.
- Drop files on her: the file paths are copied to the clipboard and Claude comes forward, ready for you to paste. The files themselves are not touched.
- Right-click her: the menu.

| Menu item | What it does |
| --- | --- |
| Open Claude | brings the Claude desktop app forward |
| Pet | switches between the pets installed in `~/.petdex/pets` and `~/.codex/pets` |
| Size | Small, Medium, Large, Extra Large |
| Stay Put | no wandering and no desktop visits of her own |
| Climb Walls and Ceiling | off keeps her on the floor and on windows |
| React to the Mouse | off stops the visits to the cursor, the startled jumps and the petting |
| Break and Bedtime Reminders | off stops both reminders |
| Collapse Task List | shows the badge instead of the full list |
| Swap Left and Right Walk | for spritesheets whose two running rows are drawn the other way round |
| Mess Up the Desktop, Tidy the Desktop, Visit the Desktop on Her Own | see Desktop trips |
| Clear Task List | drops every row |
| Quit | quits the app |

## Install

Requirements: macOS 13 or later, the Xcode Command Line Tools (`xcode-select --install`), Python 3, and `jq` (part of macOS 15 and later). Claude Code is needed for the task list.

1. Get a pet. Pick one at [petdex.dev](https://petdex.dev) and put its `pet.json` and `spritesheet.webp` into `~/.petdex/pets/<name>/`. With Node installed, `npx petdex install <name>` does the same into `~/.codex/pets`.

2. Build the app.

   ```bash
   ./build.sh
   ```

3. Install the Claude Code hooks. This backs up `~/.claude/settings.json` first and can be run again safely.

   ```bash
   python3 install_hooks.py
   ```

4. Start her.

   ```bash
   open ClaudePet.app
   ```

She does not start at login by herself. Quit from the right-click menu.

To remove the hooks again:

```bash
python3 install_hooks.py --uninstall
```

After that, deleting this folder and `~/.claude-pet` removes everything the project created.

## What it touches

- `~/.claude/settings.json`: 12 hooks, each of which only calls `~/.claude-pet/hook.sh` in the background. A dated backup is written next to the file on every install.
- `~/.claude-pet/`: the hook script, the event log, a process id file, the cut animation frames, and the saved desktop layout. An event holds the session id, the event name, the tool name, the session title, the working directory and the transcript path. It holds no prompt text and no tool input. Nothing is written while the pet is not running.
- Read only: the session files of the Claude desktop app, for titles, and the last 32 KB of a running session's transcript, to spot an interrupted turn. Nothing read there is stored.
- The clipboard: only when you drop files on her.
- Finder: only the positions of desktop icons and the desktop's sort order, as described above.

## Footprint

Measured on an Apple silicon laptop.

| State | CPU | Memory |
| --- | --- | --- |
| asleep | under 0.6% | 13 MB |
| standing | 1% to 2% | 13 MB |
| walking or climbing, task list shown | 4% to 6% | 14 to 15 MB |

A desktop trip adds 1 to 3 MB for a minute or so.

How it stays small:

- The animation frames are cut once by a short-lived helper process and stored as compressed files. The app maps those files and expands at most two clips at a time.
- The loop runs at 4 to 30 steps per second depending on what she is doing.
- The task list, the bubble and the carried icon are child windows of the pet window, so they move with it for free.

## Project layout

| Path | Role |
| --- | --- |
| `Sources/App/` | start-up, command line modes, every path and tuning number (`PetConfig.swift`) |
| `Sources/Pet/PetController.swift` | the loop, the shared state, drawing and window placement |
| `Sources/Pet/PetMovement.swift` | entrances, walking, falling, jumping, walls and the ceiling |
| `Sources/Pet/PetBehavior.swift` | choosing what to do, mouse play, sleep and reminders |
| `Sources/Pet/PetErrand.swift` | the trips across the desktop |
| `Sources/Pet/PetClaude.swift` | reactions to Claude, task list rows, opening sessions |
| `Sources/Pet/PetMenu.swift` | mouse gestures, dropped files, the menu, debug commands |
| `Sources/Pet/PetOverlay.swift` | where the task list and the bubble go |
| `Sources/Atlas/` | cutting a spritesheet into frames and reading them back from the cache |
| `Sources/Sessions/` | reading hook events, tracking each session, session titles |
| `Sources/Windows/` | the transparent panels, the task list view, the window scanner |
| `Sources/Desktop/DesktopMischief.swift` | reading the desktop through Finder, saving and restoring its layout |
| `Sources/Desktop/DesktopIconMover.swift` | moving one icon at a time with a direct Apple event, off the main thread while she carries it |
| `hooks/hook.sh` | called by Claude Code for each event, appends one line to the event log |
| `install_hooks.py` | installs or removes the hooks |
| `build.sh` | compiles everything under `Sources` and assembles `ClaudePet.app` |

After changing code, run `./build.sh`, quit the running pet and open the new one. When the frame cutting changes, raise `PetConfig.atlasCacheVersion` so the cache is rebuilt.

## Debugging

Check how a spritesheet is cut. This prints the frame count of each clip and writes a contact sheet:

```bash
ClaudePet.app/Contents/MacOS/ClaudePet --dump-atlas ~/.petdex/pets/<name> sheet.png
```

Ask the running pet for its state, written to `~/.claude-pet/debug.json`:

```bash
touch ~/.claude-pet/debug-request
```

Write a command into `debug-request` to direct her:

| Command | Effect |
| --- | --- |
| `jump` | jump to another ledge |
| `drop 760 800` | fall from a point |
| `walk left`, `walk right` | walk one way |
| `climb left`, `climb right` | start climbing that side |
| `enter` | enter the screen again |
| `sleep`, `awake 600` | sleep; wake up and stay awake for 600 seconds |
| `remind`, `night` | show the break reminder, the bedtime reminder |
| `click` | same as clicking her |
| `board-click 0`, `board-click 0 dry` | click the first task list row; `dry` only records the link |
| `board-toggle` | collapse or open the task list |
| `mouse rush`, `mouse pet`, `mouse rest` | play back a scripted cursor path |
| `snapshot /tmp/pet.png`, `snapshot-board /tmp/board.png`, `snapshot-icon /tmp/icon.png` | save a picture of the pet, the task list, or the carried icon |
| `desktop-rehearse` | run a trip with made-up icons that never touches Finder |
| `desktop-probe` | read the desktop without changing it |
| `desktop-mess 4`, `desktop-tidy` | start a trip with 4 icons; start the tidy-up |
| `desktop-restore` | put every icon back at once |

## Artwork

Pets come from the community at [petdex.dev](https://petdex.dev). Each pet belongs to its author, and many are fan art. Please respect their terms. This repository ships none of them.
