# Keyboard and pointer

Lumen's controls work the way Mac controls do from the keyboard and pointer. This page covers
keyboard operation, focus, shortcuts, menu bar commands, click targets, signals beyond color and
readability in the standard themes. VoiceOver, Reduce Motion, Increase Contrast, text scaling and
right-to-left layout are outside its scope; the VoiceOver labels and Reduce Motion handling already
in the code stay as they are.

## Reaching and operating controls

- Buttons (toolbar buttons, panel toggles, the new-item button, inspector section headers, the
  info and color buttons) behave as native buttons: with Full Keyboard Access on (System Settings ›
  Keyboard › Keyboard navigation), Tab reaches them and Space presses them.
- Selection groups are one Tab stop each, like a segmented control, and ←/→ move the selection:
  `LumenPanelTabs`, `LumenFilterChips`, `LumenSidebarSwitcher`, `LumenDocumentTabBar`,
  `LumenModeSwitcher` and `LumenHueSwatchPicker` (the inspector's hue row). The swatch grid in the color popover also moves with ↑/↓ and is ready for
  arrows when it opens. The welcome window's recents move with ↑/↓ and open with Return.
- A focused group draws its own focus ring (`border.focus`) around the selected item.
- Every Lumen-drawn button that's a Tab stop shows a focus ring in `border.focus`. The plain button
  style draws none, and on macOS a button style can't see keyboard focus, so the ring sits on the
  button: `.buttonStyle(.lumenPlain).lumenFocusRing()`. Apps use the same pair for their own
  buttons drawn in Lumen's styles, `LumenToolbarIconButtonStyle` included. The status bar's
  borderless menus get one the same way.
- `LumenSidebarSection(_:actions:content:)` draws header buttons with 24 pt targets, focus rings and
  help tags. With the `accessory:` form, an app's own buttons get the native borderless style, which
  draws the system focus ring.

- Menus Lumen draws (the command menu, the launch menu) take the keyboard when they open: ↑/↓ move,
  → opens a submenu and moves into it, ← closes it, Return chooses, Escape closes. One view owns
  the keyboard for the whole menu, submenus included. In a popover, submenus open in place under a
  back row. Native popovers close with Escape.
- The command palette focuses its search field when it opens, ↑/↓ move through results, Return
  runs, and Escape closes it wherever focus is. Closing it returns focus to the window rather than
  to whatever text field AppKit would pick next.
- `LumenFilterField`: Escape clears the filter, then leaves the field.

With Keyboard Navigation on, in the Catalog's workspace window: Tab
reaches the sidebar switcher, filter field, section buttons, document tabs, status menus, panel tabs
and the Navigator toggle, each with a visible ring; ←/→ move the switcher, document tabs and panel
tabs. Two things are macOS's, not Lumen's:

- Tab also visits the window's title bar buttons (minimize, zoom), which macOS draws itself.
- In a SwiftUI toolbar, Tab reaches only the first control; the other toolbar items are skipped.
  Their commands are in the menu bar with shortcuts (`LumenViewCommands`: ⌃⌘S, ⇧⌘Y, ⌥⌘I), as Mac
  convention expects every toolbar command to be. Give a new-item button a menu equivalent too.

## Focus

- `LumenFilterField` hands back the focus AppKit gives a new window's first text field, so a
  sidebar filter doesn't capture typing meant for the content. Pass `takesInitialFocus: true` for
  a field that should start focused.

## Shortcuts

All of them are in `LumenShortcuts`, and a test checks that they're distinct and clear of macOS's
system and standard app shortcuts (⌘Q, ⌘W, ⌘H, ⌥⌘H, ⌘M, ⌘,, ⌘N, ⌘O, ⌘S, ⇧⌘S, ⌘P, editing, ⌘F/⌘G,
⌘T, ⌘`, ⌘Tab, ⌘Space, ⌃⌘Space, ⌃⌘F, ⌃⌘Q, ⇧⌘Q, ⇧⌘?, screenshots, ⌥⌘D, ⌥⌘Esc).

| Shortcut | Command | Precedent |
|---|---|---|
| ⌃⌘S | Show/Hide Navigator | macOS sidebars |
| ⇧⌘Y | Show/Hide Panel | Apple developer tools' debug area |
| ⌥⌘I | Show/Hide Inspector | Pages, Keynote, Numbers |
| ⇧⌘[ / ⇧⌘] | Select Previous/Next Tab (wrap) | Safari |
| ⌘1…⌘9 | Sidebar panes | Apple developer tools' navigators |
| ⌘K | Command Palette | Quick command bars in many Mac apps |

⌘K adds a link in text editors (Pages, Mail, Notes); such an app gives the palette another
shortcut. ⌘1…⌘9 clash with apps that use them for tabs or view modes (Safari, Finder). Such an app passes
`shortcuts: false` to `LumenSidebarSwitcher`. Icon-only buttons name their shortcut in the help tag.

## Menu bar

Every toolbar command is also in the menu bar. Add `LumenViewCommands()` to your scene's
`.commands` and publish the window's panels with `.lumenPanelCommands(leading:bottom:trailing:)`:

- View › Command Palette… (⌘K), from the focused window's `.lumenCommandPalette`.
- View › Show/Hide Navigator, Panel and Inspector, titled for the current state. Without a
  navigator binding the item falls back to the standard Toggle Sidebar action.
- Window › Select Previous/Next Tab, from the focused window's `LumenDocumentTabBar`. They're named
  apart from macOS's own Show Previous/Next Tab items for window tabs.

When the menu owns the shortcuts, apply `.lumenMenuOwnsShortcuts()` once at the window's root: the
toolbar toggles, inspector toggle, sidebar switcher and command palette then register none, so each
shortcut has one owner. (Per control, `registersShortcuts: false`, `registersShortcut: false` and the
palette's `shortcut: nil` do the same.) Publish the window's sidebar panes with
`.lumenPaneCommands(_:selection:showsNavigator:arrangement:)` for View › Show <pane> (⌘1…⌘9), which
also reveals a collapsed navigator; without it the sidebar switcher's own ⌘1…⌘9 apply.

An app whose own shortcuts clash changes them in one place, `LumenViewShortcuts`, and passes the set
to `LumenViewCommands(shortcuts:)` and `LumenPanelToggles(shortcuts:)`, which show it in their menu
items and help tags. `LumenViewCommands(commandPalette: false)` leaves out the palette item for an
app with its own palette; `tabNavigation: false` leaves out the tab items; `sidebarFallback: false`
leaves out Toggle Sidebar in an app whose sidebar doesn't collapse.

```swift
var shortcuts = LumenViewShortcuts.standard
shortcuts.panel = KeyboardShortcut("y", modifiers: [.control, .command])   // ⇧⌘Y is taken
LumenViewCommands(shortcuts: shortcuts, commandPalette: false)
```

## Click targets

Every control Lumen draws has a hit area of at least 24 × 24 pt
(`metrics.layout.minimumHitTarget`), even where it looks smaller: tab close buttons, the info
button, the copy button, swatches, chips, tinted buttons, the color button and status bar items.
Command menu rows are 22 pt, as native menu rows are: they aren't Tab stops, and the menu's rows
form one continuous target.

## Signals beyond color

Selected and active states also show a shape: filled tabs, chips and menu rows, the panel
toggles' filled region, the swatches' ring and check, the edited dot, status icons, and a
background behind the selected sidebar pane.

## Readability in the standard themes

On top of the existing text and graphic contrast checks, the validator checks:

- `fg.primary` and `fg.secondary` on `bg.hover`, and `sidebar.foreground` on `sidebar.rowHover`
  (an inverted sidebar must set its hover fill too)
- `fg.primary` and `fg.secondary` on the selection, active and inactive (`bg.selected`,
  `bg.selectedInactive`); `sidebar.foreground` on `sidebar.rowSelected` and
  `sidebar.rowSelectedInactive`, and `sidebar.secondaryForeground` on `sidebar.rowSelectedInactive`
- on raised grounds (cards, popovers, sheets, menus): `fg.primary` and `fg.secondary` on
  `bg.hoverRaised` and `bg.selectedInactiveRaised`; each of those visible against `bg.elevated` and
  told apart from each other; and every contrast pair that uses a raised role checked again on the
  raised ground
- `fg.disabled` at 2:1 on the canvas, window, sidebar, selection, cards and raised wells, so disabled
  text stays perceivable
- disabled toolbar buttons (drawn at 45%) at 2:1 on the toolbar and the title bar glow

A test holds glyphs' full-strength marks at 3:1 against their tint layer, in text colors and in
every tile hue in every theme. Inside tiles the tint deepens the hue under white glyphs (and
lightens it under dark ones), because a lightening tint cut white marks to about 2.2:1.
