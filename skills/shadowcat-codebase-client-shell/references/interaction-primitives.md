# Shell interaction primitives: Escape, dialogs, drag, menus, notifications, keybindings, folders

Shared client interaction seams in `@shadowcat/core` and `@shadowcat/ui-kit`. Read it before adding a keydown listener, a dialog, a drag interaction, a context menu, a notification or a keyboard shortcut.

## Escape and dialogs

- `EscapeCoordinator` / `ESCAPE_PRIORITY` (core) is the ONE Escape handler: a capture-phase listener that dispatches to registered handlers by priority, then recency; a handler may carry an `appliesTo` filter. Invariant: a component REGISTERS with the coordinator, it never installs its own Escape keydown. Floating panels register through the panel host's floating-escape subscription list (see `shadowcat-codebase-panels`); `ContextMenu` registers at `ESCAPE_PRIORITY.MENU`.
- A `MODAL` priority handler swallows Escape from other window listeners, so a modal that needs Escape for something else (a key-capture field) must handle it inside the modal.
- `trapFocus`, `ConfirmDialog` / `PromptDialog` and the promise helpers `confirmDialog` / `promptDialog` replace `window.confirm` and `window.prompt`. `DialogHost` is mounted in the shell's `Table.svelte`, not contributed as a surface; a test that renders a component calling `confirmDialog` must mount `DialogHost` too.
- `createMenuKeyboard` (activate/deactivate) drives every menu's arrow/enter handling; `ContextMenu` is built on it.

## Drag and drop

`createDragController` (core `dnd`) is the one pointer-event drag implementation: no native HTML drag. Touch starts after a long-press (350 ms); axes and drop targets are options (`dropTargets`, `onDrop`, `onHover`, `snapToNearest`); `dropIndex` computes the slot and `DropResult` carries string ids. Reordering is decided by ONE pair: `computeReorderUpdate` / `buildReorderOps` (sort-key based, the shared sort-key primitive), used by the combat tracker, `NoteTree` (drag handle plus Alt+Arrow, disabled while searching), `FolderTree` and `AssetGrid`. Dropping onto the middle half of a folder row means "into"; `ROOT_DROP_ID` clears the folder; OS file drops stay native.

## Context menus

`createContextMenuTrigger` (ui-kit `contextMenu`) opens on right-click and on touch long-press (500 ms, 10 px slop; the 350 ms drag long-press staggers under it on purpose). The CONSUMER owns the open state and passes `canOpen`, which must refuse while a drag is active. Menu items call the same handlers as the visible buttons. `ContextMenu` is 44 px touch-sized and clamps to the viewport. `NoteTree` hosts the note menus; `NotesPanel` only lists rows.

## Notifications

`NotificationCenter` entries may carry progress: `AppContext.notifyProgress` returns a handle whose `update` changes the bar; the owner MUST dismiss the handle when the work ends (a progress row never auto-dismisses). `NotificationHost` renders the message area as a native button element sibling of the action and dismiss buttons (44 px) so the whole row dismisses without a row click handler or event-propagation stop; do not reintroduce a handler on the row. Progress rows render no dismiss button. The dismiss label key is `notifications.dismissMessage`.

## Keybindings

`KeybindingsController` (core) is the single store of keyboard shortcuts: modules register through `ModuleContext.keybindings` (`Deps.keybindings`), the `core:keydown` hook feeds it, and unloading a module removes its bindings. Overrides persist in `UiState.global.keybindings` through `sessionState` and are kept for unregistered bindings. On a shared combo the lowest registration order wins; auto-repeat is ignored. The settings `KeybindingsSection` captures keys through `escapeCoordinator`. The push-to-duck key is a keybinding (per account), not a per-device ducking preference. `registerSetting` + `SettingRow` build a module's setting rows.

## Folder trees and tags

`DocFolderTree` (ui-kit; props `folderDocType`, `labels`, `rootDropId`, `deleteChoices`, `onDelete`, `buildFolder`, `dropHover`, typed helpers in `folderTree`) is the one folder tree; the asset browser's `FolderTree` is a thin wrapper and `TablesPanel` uses it for table folders (`TABLE_FOLDER_DOC_TYPE`, `buildTableFolderDoc`, `buildTableDoc` with a parent id). `TagChips`, `ConditionTogglePalette`, `PermissionsEditor` and `UserMultiSelect` are ui-kit components shared across modules. `EffectsList` (`listEffects` mirrors the server's host walk, including transfer and anchor rules) is mounted in the combatant row and the actor sheet; `SheetHost` has no extension point, so a sheet mounts such components itself.

## Test gotchas

- A test file name that differs from another only by case collides on a case-insensitive filesystem; keep test file names distinct beyond case.
- A drag or menu test never touches layout (jsdom has none): it drives pointer events by hand and declares its environment explicitly, per the core skill's vitest invariant.
