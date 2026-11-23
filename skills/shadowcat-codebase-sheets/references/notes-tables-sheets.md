# Sheets: notes and tables sheets

Part of the shadowcat-codebase-sheets skill; read it when changing the note or table sheet modules.

## Notes/tables sheets

`@shadowcat/module-sheet-note` (`NoteSheet.svelte`, `sheet-note:sheet`, priority 0) and
`@shadowcat/module-sheet-table` (`TableSheet.svelte`/`RowEditor.svelte`/`EntryEditor.svelte`,
`sheet-table:sheet`, priority 0) are the shipped sheets for `NOTE_DOC_TYPE`/`TABLE_DOC_TYPE`. Both
follow this skill's `basePrefix` derivation pattern (in the Key files & seams section of SKILL.md) exactly — `/engine/source` (note) and
`/engine/rows`/`/engine/draw`/`/engine/description` (table) are ordinary `enginePrefix` writes
through `setField`/`setFields`, never a hand-derived path shape.

- **Note body:** `NoteSheet` renders `note-docs.ts`'s `parseNoteBody(doc)` output through
  `@shadowcat/ui-kit`'s `SegmentList` (the same renderer `module-chat-card` uses for a message's
  `content` — see `shadowcat-codebase-chat`), never a bespoke renderer, with `channel =
  firstChannel(ctx.documents) ?? ""` and the body wrapped in `<fieldset disabled={channel === ""}>`
  — roll buttons inside it are inert until the channel registry resolves. `NoteEngine.body` is
  SERVER-DERIVED (`data::engine::note`'s ingress arm unconditionally overwrites it) — the sheet
  never constructs or edits it directly.
- **Draft-base OCC (the note-save rule):** opening the editor seeds BOTH a live `draft` and an
  immutable `draftBase` snapshot of the stored `source`; Save dispatches exactly ONE
  `setField(ctx, docId, sourcePath, draftBase, draft)` — the OCC `old` is the draft's BASE, never
  the live stored value at save time. A concurrent remote edit therefore makes the server refuse
  with `conflict` (surfaced by the shell-wide reject toast, see `shadowcat-codebase-client-shell`)
  instead of silently overwriting it; the draft is retained (a "changed remotely" banner renders
  when `storedSource !== draftBase`) so the author reconciles by hand or discards via Reload
  (which re-seeds both from the CURRENT stored value, never the stale draft).
- **Note visibility:** a `/permissions/default` (`"none"`/`"observer"`) select, rendered under
  `ctx.canEdit(doc, "/permissions/default")` — true for the author via `grantAuthor`'s
  `core:edit_permissions` grant (`shadowcat-codebase-documents-permissions`) and for a GM. Sharing
  never demotes the author's own `Owner` entry.
- **Note sharing and presenting:** the sheet mounts ui-kit's `PermissionsEditor` (default role, per-user
  overrides through `UserMultiSelect`, an opt-in GM role; it reads the stored permission set raw as the
  OCC old value and is gated on `canEdit` of `/permissions`). `SheetHost` has no extension point for
  it, so the sheet mounts it directly. The "Present to players" button shares a private note first
  with an ordinary visibility Update, then calls `ctx.notes.present`; the server never presents an
  unshared note, and a refusal surfaces as a notice.
- **Note pages and TOC:** `NoteEngine.kind` (`NotePageKind` text, image, pdf, video; the media kinds
  carry an `asset_id`) is read with `parseNotePageKind`, which fails closed to text; the media block
  renders through `ctx.assets.url` with a placeholder for a deleted or failing asset, and "Change
  media" uses `pickAsset`. The table of contents comes from `collectHeadings` over the RENDERED
  h1-h6 (so setext headings and raw HTML headings count) and an in-note `#fragment` click is
  intercepted to scroll with `findAnchor` instead of navigating; the sanitizer admits fragment-only
  URLs for exactly this (see `shadowcat-codebase-chat`).
- **Note tree:** children come from `ctx.documents.query(NOTE_DOC_TYPE)` filtered
  `parent_id === docId`, ordered by `(engine.sort, created_at)`; "New child note" (gated on
  `ctx.canCreate(NOTE_DOC_TYPE)`) calls `buildNoteDoc(ctx.world, t("sheetNote.untitled"), "",
  { parentId: docId, owner: ctx.selfId })` then opens it. The notes PANEL builds the same shape
  for the whole tree via `buildNoteTree` (`shadowcat-codebase-client-shell` — the notes module).
- **Table rows/entries — whole-array writes:** every row/entry mutation (`addRow`/`removeRow`/
  `moveRow`/`setRow` in `sheet-table`'s `rowOps.ts`) replaces the WHOLE `engine/rows` array via
  `setField`, committed on the DOM change event (blur/select), never the input event — `set_pointer` cannot resize
  an array, and per-keystroke writes would churn OCC against a concurrent editor. Switching the
  draw rule (`setDraw`) writes `engine/draw` AND a reshaped `engine/rows` (via
  `normalizeRowsForDraw`) as ONE atomic `setFields` call, since `TableEngine::validate` requires
  every row's `range` to agree with the new rule against the whole post-image.
- **Table Draw:** `ctx.chat.drawTable({ tableId: docId, channel, count })` with `channel =
  firstChannel(ctx.documents)`, disabled while `null`; the server's player-presentable refusal
  (over-cap count, empty table, cycle, missing asset, rate limit) is surfaced VERBATIM via
  `ctx.notify` — no client-side draw-count cap duplicates `MAX_TOP_LEVEL_DRAWS`. The entry
  pickers (`doc`/`draw` kinds in `EntryEditor`) use `ctx.searchDocuments(q, { limit, docTypes })`
  — `docTypes: [TABLE_DOC_TYPE]` for the table picker — no client-side re-filter.
- **Neither sheet carries a delete control.** Deletion lives in the panels — `NoteTree` and
  `TablesPanel` — gated on `ctx.canDelete(doc)` (`shadowcat-codebase-client-shell`'s
  `canCreate`/`canDelete` mirrors), never raw `doc.owner === ctx.selfId`: ownership is not a
  capability on either doc_type.

Full engine-body shapes and server-side seams: `shadowcat-codebase-tables-notes`.
