# ModDrag

ModDrag is a lightweight Swift CLI that lets you move and resize macOS windows by holding configurable shortcuts. It relies only on public accessibility APIs and does not require any additional daemons or helpers.

## Features

-   Configurable drag and resize shortcuts that can be modifier-only or a key plus modifiers
-   Smooth window movement with 240 Hz rate limiting for responsive tracking without unnecessary CPU load
-   Seamless switching between dragging and resizing while keeping the same window captured
-   Safety controls: press the `Esc` key to cancel the current action or `Ctrl+C` to terminate the app
-   Built-in guards that skip fullscreen or minimised windows and enforce a minimum window size

## Build

```bash
swiftc -O -parse-as-library main.swift -o mod-drag
```

If the compiler reports that it cannot write the Swift module cache, re-run the command with sufficient permissions (the tool needs to write to `~/Library/Developer/Xcode/DerivedData` or `~/.cache/clang/ModuleCache`).

## Usage

1. **Run the binary**

    ```bash
    ./mod-drag
    ```

2. **Grant accessibility access** (first run only and if needed)

    - Open **System Settings → Privacy & Security → Accessibility**
    - Press the **"+"** button and add the compiled `mod-drag` binary
    - Restart the binary after granting access

3. **Interact**

    - Hold the drag shortcut and move the mouse to relocate the window under the cursor
    - Hold the resize shortcut and move the mouse to resize the captured window
    - Press `Esc` to abandon the current operation

Console logs show the current state (`Idle`, `Armed`, `Dragging`, `Resize Armed`, `Resizing`) so you can confirm what the tool is doing at any moment.

## Default Shortcuts

The defaults live in `WindowDraggerConfiguration.default` inside `main.swift`:

```swift
static let `default` = WindowDraggerConfiguration(
    dragHotKey: HotKeyConfiguration(
        keyCode: 0,
        modifiers: [.maskCommand, .maskControl]
    ),
    resizeHotKey: HotKeyConfiguration(
        keyCode: 0,
        modifiers: [.maskShift, .maskCommand, .maskControl]
    ),
    emergencyStopKeyCode: 53,
    minimumWindowSize: CGSize(width: 100, height: 100),
    updateInterval: 1.0 / 240.0
)
```

-   `keyCode: 0` means “modifier-only” behaviour; the shortcut fires as soon as the listed modifiers are held.
-   Use `keyCode` with a non-zero value (for example `49` for Space or `96` for F5) to require an explicit key press.
-   `emergencyStopKeyCode` is the macOS key code for the emergency stop key (`53` is `Esc`).
-   The `minimumWindowSize` guard prevents collapsing a window below 100×100 points.

### Finding key codes

macOS key codes differ from printable characters. Useful references:

-   49 – Space
-   53 – Esc
-   96 – F5
-   97 – F6
-   98 – F7
-   99 – F8

You can add new codes to the `keyName(for:)` helper if you use additional keys and want them to appear nicely in the console output.

## Customising Behaviour

-   Adjust the `dragHotKey` and `resizeHotKey` values to tailor the shortcuts to your workflow.
-   Change `minimumWindowSize` if you prefer a different lower bound when resizing.
-   Modify `updateInterval` to raise or lower the refresh rate. Lower values increase CPU usage but make movement more responsive.

Rebuild the binary after any changes:

```bash
swiftc -O -parse-as-library main.swift -o mod-drag
```

## Troubleshooting

-   **The app exits immediately** – ensure the binary has accessibility permission. The tool prints detailed instructions when the permission is missing.
-   **A window does not move** – some system or sandboxed apps disallow programmatic movement; the tool skips those windows.
-   **Logs show “Failed to move/resize window”** – the app probably rejected the accessibility command. Releasing and re-engaging the shortcut usually resets the state.
