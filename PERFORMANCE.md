# Performance

Measured, not described. The harness is `Benchmarks/VaultBench`, a synthetic vault
of 500 items × 8 fields (4,000 fields, ~1.2 MiB of JSON, ~1.7 MiB encrypted).

```sh
swift build -c release --product VaultBench
.build/release/VaultBench --items 500 --fields 8 --runs 7
```

Each number is the median of seven runs after a warm-up. `main-thread block` is
the longest stretch the main actor went without servicing a 1 ms ticker while the
operation ran; that is the number that decides whether typing or launching feels
laggy. Wall time still matters for how long the work takes somewhere else.

Machine: 2026 MacBook Air, release build. The host was busy (load average ~6) when
the numbers were taken, so treat absolute milliseconds as an upper bound and the
ratios as the signal.

## Results

| Operation | Before | After |
|---|---:|---:|
| Search, empty query (all fields) | 3.92 ms | **0.65 ms** |
| Search, one letter (`e`, ~4,000 hits) | 6.43 ms | **3.52 ms** |
| Search, no match | 4.99 ms | **2.01 ms** |
| Open the vault (file → payload) | 75 ms | 75 ms |
| Open: **main-thread block** | 75 ms | **2.1 ms** |
| One autosave (encrypt + write) | 37 ms | 50 ms |
| Autosave: **main-thread block** | 37 ms | **2.7 ms** |
| App launch: palette panel construction | 209 ms | **0 ms** (deferred) |
| Editor save frequency | every keystroke | once per 250 ms idle burst |

"Before" for the two block rows is the old synchronous path: `mutate` and
`performOpen` were plain functions called on the main actor, so their whole
runtime was main-thread time. That path is still in the benchmark as
`legacy save on main (old path)` so the comparison stays honest.

### Quick Fill (Control+Option+V)

Measured inside the app, with another application frontmost and the panel
already warmed: **10–51 ms** from hotkey handler to the panel holding key across
runs on a loaded host, of which 9–14 ms is the window being ordered front and
made key, and under 1 ms is focus capture plus the unfiltered search. Native verification records this as
`paletteOpenMilliseconds` and fails above 500 ms.

Each keystroke after that costs 0.65–3.5 ms of search at 4,000 fields. The panel
resizes without animation and the resize is coalesced and deferred out of the
display cycle, because resizing a window from inside a SwiftUI update re-enters
AppKit layout and aborts the process.

## What changed

1. **Saves left the main thread** (`VaultSession.mutate`). Encoding, AES-GCM, and
   the atomic file write now run in a `VaultMutationWriter` actor. A gate
   serialises mutations so two edits can never race for the same expected bytes,
   and a generation check prevents a write that finished after a lock from
   republishing the payload.
2. **Opening the vault left the main thread** (`VaultSession.openVault`). The
   Keychain read, file read, and decryption run in a detached task; only the
   publish happens on the main actor. This is why launch no longer waits on
   decryption before the first window can draw.
3. **Editor writes are coalesced** (`ItemEditorView`). Each keystroke used to
   re-encrypt the whole payload and rewrite the vault file. Saves now wait for a
   250 ms pause, and the trailing edit is flushed when the item changes or the
   view goes away.
4. **Search is indexed** (`SearchIndex`). Lowercased labels, keys, aliases, titles,
   and tags are prepared once per vault version instead of per keystroke, and
   category/profile names are resolved with dictionaries instead of a linear scan
   per field. Scores and ordering match `SearchEngine`.
5. **The palette panel is built on demand** (`AppState`). Constructing the
   SwiftUI hosting view cost 209 ms of launch. It is now created after the vault
   opens, so launch is not charged for it and the first Control+Option+V still
   finds it ready.
6. **The right-click menu is bounded** (`RightClickFillController`). It built one
   `NSMenuItem` per field in the vault — thousands for a large vault. It now stops
   at 100 and points at Quick Fill for the rest.

## Still on the table

- JSON encoding/decoding is the largest remaining per-save cost (~31 ms encode,
  ~29 ms decode at 4,000 fields). The format uses ISO-8601 dates per field; a
  binary or integer-epoch format would cut most of it, but it changes the vault
  file format and needs a migration.
- The vault window is created at launch. If the app started menu-bar-only, launch
  would be limited to process start plus the menu bar item.
- The insertion path (Accessibility query, then event posting) is not measured
  here; it depends on the target application.
