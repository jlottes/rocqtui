# Terminal Features Required by Rocqtui

Reference for implementing terminal emulator support for rocqtui's mouse,
clipboard, and input features.

## Mouse Support

### Basic Mouse Tracking (X10/Normal)

Enabled by ncurses via `mousemask(ALL_MOUSE_EVENTS | REPORT_MOUSE_POSITION)`.
ncurses negotiates with the terminal using the standard `kmous` terminfo
capability and DEC private mode sequences.

### Button-Event Tracking (Mode 1002)

We explicitly enable this for drag support:

```
Enable:  \e[?1002h
Disable: \e[?1002l
```

Reports mouse motion events **only while a button is held down**. Without
this, only press/release/click events are reported — no drag tracking.

### Mouse Event Encoding

The terminal sends mouse events as escape sequences. The two main encodings:

**SGR encoding** (preferred, modern terminals):
```
\e[<Cb;Cx;Cy;M    (button press)
\e[<Cb;Cx;Cy;m    (button release)
```
Where `Cb` = button/modifier bits, `Cx`/`Cy` = 1-based column/row.

**X10/Normal encoding** (legacy):
```
\e[M CbCxCy
```
Where `Cb`, `Cx`, `Cy` are single bytes = value + 32.

ncurses handles decoding and presents events via `getmouse()` as an
`MEVENT` struct with `(x, y, bstate)`.

### Button State Bits (bstate from ncurses)

These are the `bstate` values we check (from ncurses headers, may vary):

| Bit          | Meaning            | Notes                          |
|--------------|--------------------|--------------------------------|
| `0x00000001` | Button 1 released  |                                |
| `0x00000002` | Button 1 pressed   |                                |
| `0x00000004` | Button 1 clicked   |                                |
| `0x00000008` | Button 1 dbl-click |                                |
| `0x00000010` | Button 1 triple    |                                |
| `0x00000080` | Button 2 pressed   |                                |
| `0x00000200` | Button 2 clicked   |                                |
| `0x00002000` | Button 3 pressed   |                                |
| `0x00010000` | Button 3 clicked   | Scroll up on some systems      |
| `0x00080000` | Button 4 pressed   | Scroll up (standard)           |
| `0x00200000` | Button 4 clicked   | Scroll down on some systems    |
| `0x02000000` | Button 5 pressed   | Scroll down (standard)         |
| `0x04000000` | Shift modifier      |                                |
| `0x08000000` | Ctrl/Cmd modifier   | Cmd on macOS via iTerm2        |
| `0x10000000` | Position report     | Motion event                   |

Note: scroll up/down button assignments vary by terminal. We check multiple
bits for compatibility. The modifier bits also vary — on macOS iTerm2,
Command+click sets `0x08000000`.

### What We Use Mouse Events For

| Event              | Action                          |
|--------------------|---------------------------------|
| B1 click           | Position cursor / focus pane    |
| B1 press + drag    | Select text (drag selection)    |
| B1 double-click    | Select word                     |
| Shift + B1 click   | Extend selection                |
| Cmd + B1 click     | Go-to-cursor (step to position) |
| Scroll up/down     | Scroll pane under mouse pointer |
| B1 press on border | Drag to resize pane borders     |


## Clipboard Support

### OSC 52 — Copy to System Clipboard

Used to set the system clipboard contents from within the terminal app:

```
\e]52;c;<base64-encoded-data>\a
```

- `\e]` = OSC (Operating System Command) introducer
- `52` = clipboard manipulation
- `c` = clipboard selection (`c` = clipboard, `p` = primary, `s` = secondary)
- Base64-encoded UTF-8 text
- `\a` = ST (String Terminator), alternatively `\e\\`

Sent when the user copies text with `^Y`. The terminal should decode the
base64 data and place it on the system clipboard.

**Security consideration**: Some terminals require explicit opt-in for OSC 52
write access (e.g., `AllowClipboardAccess` in iTerm2).

### Bracketed Paste Mode

Allows the terminal to send pasted text wrapped in markers so the
application can distinguish typed input from pasted text:

```
Enable:  \e[?2004h
Disable: \e[?2004l
```

When the user pastes text (e.g., Cmd+V), the terminal wraps it:

```
\e[200~<pasted text>\e[201~
```

- `\e[200~` = paste start marker
- `\e[201~` = paste end marker
- Text between markers may contain newlines, control characters, etc.

We detect `\e[200~` in our input handler, read until `\e[201~`, and
insert the text into the editor buffer.


## Input Handling

### ESCDELAY

ncurses uses `ESCDELAY` to distinguish a standalone Escape keypress from
the start of an escape sequence (`\e[A` for arrow up, etc.).

We set `ESCDELAY=25` via environment variable before `initscr()`. This
means ncurses waits 25ms after seeing `\e` before deciding it's a
standalone Escape. Longer values cause noticeable lag on Escape-based
keybindings (we use Escape for XCompose input).

### Raw Mode

We use `raw()` instead of `cbreak()` to disable terminal-level signal
processing. This ensures:
- `^C` (0x03) is delivered as a keypress, not SIGINT
- `^Z` (0x1A) is delivered as a keypress, not SIGTSTP
- `^\` is delivered as a keypress, not SIGQUIT

We handle `^C` ourselves (forward SIGINT to rocqtop) and use `^Z` for undo.

### Non-blocking Input

We use `timeout(0)` (non-blocking `getch`) and drive input via our own
`select()` loop that multiplexes stdin with the rocqtop file descriptor.
`getch` is only called when `select` indicates stdin has data.

### Key Codes We Depend On

Standard ncurses key constants from terminfo:

| Key              | ncurses constant  | Typical code |
|------------------|-------------------|--------------|
| Arrow Up/Down/L/R| KEY_UP etc.       | 259/258/260/261 |
| Home / End       | KEY_HOME/KEY_END  | 262/360      |
| Page Up / Down   | KEY_PPAGE/KEY_NPAGE| 339/338     |
| Insert / Delete  | KEY_IC/KEY_DC     | 331/330      |
| Backspace        | KEY_BACKSPACE     | 263 or 127   |
| F1               | KEY_F(1)          | 265          |
| Shift+Up/Down    | KEY_SR/KEY_SF     | varies       |
| Shift+Left/Right | KEY_SLEFT/KEY_SRIGHT | varies    |
| Shift+Home/End   | KEY_SHOME/KEY_SEND | varies      |
| Shift+PgUp/PgDn  | KEY_SPREVIOUS/KEY_SNEXT | varies |
| Mouse event      | KEY_MOUSE         | 409          |
| Terminal resize  | KEY_RESIZE        | 410          |

**Modified arrow keys** (Alt+Up/Down for stepping) require extended terminfo
entries. These are terminal-specific:

| Key        | Escape sequence | terminfo name |
|------------|-----------------|---------------|
| Alt+Up     | `\e[1;3A`       | kUP3          |
| Alt+Down   | `\e[1;3B`       | kDN3          |
| Ctrl+Up    | `\e[1;5A`       | kUP5          |
| Ctrl+Down  | `\e[1;5B`       | kDN5          |

If these aren't in the terminfo, ncurses can't recognize them and they
arrive as separate characters (Escape + `[` + `1` + ...).


## Terminal Modes Summary

Modes we enable on startup and disable on exit:

| Mode        | Enable         | Disable        | Purpose            |
|-------------|----------------|----------------|--------------------|
| Alt screen  | (via initscr)  | (via endwin)   | Preserve scrollback|
| Button-event| `\e[?1002h`    | `\e[?1002l`    | Mouse drag events  |
| Brkt paste  | `\e[?2004h`    | `\e[?2004l`    | Paste detection    |

ncurses handles the alternate screen buffer automatically via
`initscr()`/`endwin()`.


## 256-Color Support

We use 256-color mode extensively for themes. The terminfo must have
proper `setaf`/`setab` capabilities for extended colors:

```
setaf=\E[%?%p1%{8}%<%t3%p1%d%e%p1%{16}%<%t9%p1%{8}%-%d%e38;5;%p1%d%;m
setab=\E[%?%p1%{8}%<%t4%p1%d%e%p1%{16}%<%t10%p1%{8}%-%d%e48;5;%p1%d%;m
```

The basic 8-color sequences (`\e[3Xm`/`\e[4Xm`) are insufficient.

Color pair count (`pairs` in terminfo) should be at least 256 (we use
up to pair 31, but ncurses may need headroom). Setting `pairs#65536`
is safe for modern usage.


## UTF-8 Support

The terminal must handle UTF-8 encoded text correctly:

- Display multi-byte characters at correct column positions
- `wcwidth()` agreement: the terminal and the application must agree
  on character display widths. We use libc `wcwidth()` for width
  calculations. CJK-aware terminals may treat "ambiguous width"
  characters (many math symbols) as width 2 — this must match.
- Combining characters: displayed on top of the preceding character
  (zero additional width)

We call `setlocale(LC_ALL, "")` before `initscr()` to enable ncurses'
UTF-8 handling.


## XCompose Input

We implement our own XCompose input method by reading `~/.XCompose`
and the system compose file (`/usr/share/X11/locale/*/Compose`).
The Escape key serves as the Compose key trigger. This is application-level
— no special terminal support needed beyond delivering Escape as a keypress
(which ESCDELAY handles).
