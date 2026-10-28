# Refactor Completion Plan (Steps 2–5)

Goal: finish the original 5-step plan without breaking the script, given **no Roblox
client access**. Everything must be verifiable statically (syntax/type checks) and with
a stubbed test harness. You will do the live test afterwards.

---

## Execution status (what was actually done)

| Phase | Status | Notes |
|---|---|---|
| 0 | ✅ | **Runtime split abandoned and reverted.** Audit showed the generated split dropped ~700 lines (PLACE_CONFIG, vector/zone normalizers, S-state seeding, Feature building, the `Runtime` object). Restored the known-good `script/Core/Runtime.lua` from `HEAD`; deleted the broken `Runtime_*.lua` files. Also stripped UTF-8 BOMs from `Init.lua`/`ModuleConfig.lua` (Luau rejects them). |
| 1 | ✅ | `Init.lua` loads `ModuleConfig.lua` (remote fetch or local `require`) **before** deriving `START_ORDER`, with a fallback to the inline `MODULES`. Both lists are kept byte-for-byte identical (76 entries) and are verified by a script in the final checklist. |
| 2 | ✅ | `Core/Logger.lua` is now a real spec module (`Name`, `Dependencies`, `Start`), exposed as `Context.Logger`, gated by the new `CONFIG.VERBOSE_LOGGING`. Wired into the main silent-bail sites: missing `PlayerStats`, missing weapon weld / input handle, farm-state transitions, and profile-store decode failure. |
| 3 | ✅ | `AutoFarming.lua` split into the entry plus six helper modules (Combat, Navigation, State, UI, Smithing, Mining). The `Feature:Update` state machine and `CreateUI`/`BuildLateUI` stay in the entry. |
| 4 | ✅ | `ProfileManager.lua` split into the entry plus Storage, Global, Serialization, and Creation. There is no UI sub-module because the original file contained no profile UI code. |
| 5 | ✅ | Luau CLI harness (`tests/run-cli.ps1`) + 10 passing pure-logic tests (config normalizers, ProfileManager serialization, AutoFarming split wiring). |

### Split shape (as built)

```
Core/ProfileManager.lua               entry: shared state, S seeding, final wiring
Core/ProfileManager_Storage.lua       file storage, pinned/global read+write
Core/ProfileManager_Global.lua        global store, pinned normalization, migration
Core/ProfileManager_Serialization.lua serialize/deserialize, compact profile
Core/ProfileManager_Creation.lua      defaults, capture/apply, create/load/delete

Features/AutoFarming.lua              entry: Update loop, CreateUI, BuildLateUI
Features/AutoFarming_Combat.lua       EnsureWeaponDrawn*, TryConsumePotion, TryHeal
Features/AutoFarming_Navigation.lua   ApproachTarget, RunGather
Features/AutoFarming_State.lua        SetFarmState, DescribeChase, RunSideJobs
Features/AutoFarming_UI.lua           stat helpers, RegenStamina, RenderUpdate
Features/AutoFarming_Smithing.lua     hook point (no-op; logic still in AutoSmithing)
Features/AutoFarming_Mining.lua       hook point (no-op; logic still in AutoMining)
```

Every helper module attaches its functions to the existing `AICFeature` table, so
call sites outside the entry (`Bootstrap`, `AutoMining`, `AutoSmithing`, `BossNavigator`,
`MobGather`) keep working unchanged. Each helper declares `Dependencies = {"AutoFarming"}`
so it always starts after the entry that owns the `Feature` table.

### Known follow-ups after in-game testing

- `AutoFarming_Smithing.lua` / `AutoFarming_Mining.lua` are intentional placeholders.
  Moving `SmithingStep` / `MiningStep` into them is the next extraction; until then the
  real implementations stay in `Features/AutoSmithing.lua` and `Features/AutoMining.lua`.
- `Runtime.lua` was **not** split. A blind split of that closure already lost state once;
  it needs an in-game test between each extraction.

---

## 0. Blockers found during audit (fix these first)

> **Historical note:** this section describes the abandoned Runtime split. The split was
> reverted (see Execution status); `Runtime.lua` is back to the known-good `HEAD` version.
> The text is kept only as a record of what went wrong.

These are not optional; the script does not currently load.

### 0.1 `script/Core/Runtime_Utilities.lua` and `script/Core/Runtime_Constants.lua` are corrupt
Both files are **one physical line** containing literal `\n` escape sequences instead of
real newlines (e.g. `-- header\n-- more\n\nreturn {...}`). Because the file starts with
`--`, the entire body is commented out, so `loadstring` returns `nil` and
`checkSpec` fails with `Invalid module: Core/Runtime_Constants.lua`.

- **Fix:** rewrite both files with real newlines (re-indent from the escaped text).
- **Verify:** `(Get-Content file | Measure-Object -Line).Lines` must be > 1; the file must
  end with a real `return { Name = ..., Start = function(Context) ... end }`.

### 0.2 Runtime split wiring is inconsistent
`Runtime.lua` does `local AICConfig = Context.Runtime_Constants`, but `Runtime_Config`
*also* returns an `AICConfig`. Confirm which table owns the constants/normalizers and make
the wrapper match the sub-module return shapes exactly:
- `Runtime_Config.Start` returns `{ CONFIG, Feature, AICConfig, NormalizeIdList }`
- `Runtime_Layers.Start` returns `{ AICConfig, AICProfile, AICCombatUtils, AICCombat,
  AICFeature, AICUI, AICDebug, UIRef, PatrolState }`
- `Runtime_Services.Start` returns `{ Services, Player, PlayerGui, UI }`
- `Runtime_Utilities.Start` returns `{ UpdateCharacter }` **and** sets `Context.Set*`/`Get*`
- `Runtime_Constants.Start` returns the `AICConfig` table directly

- **Fix:** decide one owner for `AICConfig` (recommended: `Runtime_Constants`, since the
  tuning + normalize functions live there) and remove the duplicate from
  `Runtime_Config`/`Runtime_Layers` or explicitly document precedence.
- **Verify:** grep every `Context.AICConfig`, `Context.Runtime_*` use and confirm shape.

### 0.3 `Init.lua` START_ORDER is computed before ModuleConfig is applied
`START_ORDER` is built from the hardcoded `MODULES` array at the top of the file, *before*
`loadRemote()` runs. The Step 2 change assigns `MODULES = Config.START_ORDER` inside
`loadRemote()`, so it changes what is *fetched* but **not** the order modules *start* in.
Also the hardcoded fallback `MODULES` does not list the `Runtime_*` sub-modules, so if the
`ModuleConfig` fetch fails the runtime deps are never downloaded.

- **Fix:** make `ModuleConfig.START_ORDER` authoritative *before* deriving `START_ORDER`,
  and add the `Runtime_*` entries to the fallback array. Keep the fetch-failure fallback.

### 0.4 Detailed remediation procedure (runtime split)

**A. Repair the two corrupt files.**
They contain literal `\n` escape text, not real newlines. Convert in place, then review:

```powershell
foreach ($f in 'script/Core/Runtime_Utilities.lua','script/Core/Runtime_Constants.lua') {
    $raw   = Get-Content $f -Raw
    $fixed = $raw -replace '\\n', "`n"
    Set-Content $f $fixed -NoNewline
}
```

After conversion the files must be multi-line and end with a real `return { ... }`:

- `Runtime_Utilities.lua` → ~115 lines, returns `{ Name = "Runtime_Utilities", Dependencies = {...}, Start = function(Context) ... end }`, and its `Start` returns `{ UpdateCharacter = UpdateCharacter }` while setting `Context.Set*/Get*`.
- `Runtime_Constants.lua` → ~180 lines, returns `{ Name = "Runtime_Constants", Dependencies = {"SaveConfig"}, Start = function(Context) ... end }`, and its `Start` returns the `AICConfig` table directly (constants + `NormalizeWaitList`, `NormalizeJumpList`, `CheckJumpWaypoint`, `NormalizeZonePairs`, `CloneTargetList`).

The reconstructed text is exactly what the escaped content encodes. Cross-check it against the
pre-split original before trusting it:

```powershell
git show HEAD:script/Core/Runtime.lua > $env:TEMP\orig_runtime.lua
# every symbol in the reconstructed files should also appear in the original:
Select-String $env:TEMP\orig_runtime.lua -Pattern 'NormalizeWaitList|NormalizeJumpList|NormalizeZonePairs|CloneTargetList|JUMP_PROBE_DISTANCE|MAX_WAYPOINT_WAIT'
```

**B. Fix the wiring in `Runtime.lua`.**
Match each sub-module's `Start` return shape exactly:

| Sub-module | `Start` returns | `Runtime.lua` should set |
|---|---|---|
| `Runtime_Config` | `{ CONFIG, Feature, AICConfig, NormalizeIdList }` | `Context.CONFIG`, `Context.Feature` |
| `Runtime_Layers` | `{ AICConfig, AICProfile, AICCombatUtils, AICCombat, AICFeature, AICUI, AICDebug, UIRef, PatrolState }` | `Context.AICProfile`, `Context.AICCombatUtils`, `Context.AICCombat`, `Context.AICFeature`, `Context.AICUI`, `Context.AICDebug`, `Context.UIRef`, `Context.PatrolState` |
| `Runtime_Services` | `{ Services, Player, PlayerGui, UI }` | `Context.Services`, `Context.Player`, `Context.PlayerGui`, `Context.UI` |
| `Runtime_Utilities` | `{ UpdateCharacter }` (+ `Context.Set*/Get*`) | `Context.UpdateCharacter`; `Context.Set*/Get*` already set |
| `Runtime_Constants` | `AICConfig` (direct table) | `Context.AICConfig` |

- **Single owner for `AICConfig`:** `Runtime_Constants` owns the tuning constants and
  normalizers, so `Context.AICConfig = Context.Runtime_Constants`. Remove the duplicate
  `AICConfig` from `Runtime_Config`/`Runtime_Layers` returns (or keep them empty and
  document that they are placeholders) so there is no ambiguity.
- `Runtime_Config.Start` currently returns `AICConfig` *and* `Runtime_Constants.Start`
  returns one. Delete the `Runtime_Config` one or alias it to `Runtime_Constants`; do not
  leave two independent tables.
- `Runtime_Utilities` reads `Context.Runtime_Config.AICConfig` — change that to
  `Context.Runtime_Constants` (or drop the unused local).
- Remove the no-op lines in `Runtime.lua` that assign `Context.SetCharacter =
  Context.SetCharacter` etc. (they are already set by `Runtime_Utilities.Start`).

**C. Verify the repair (no Roblox needed).**

```powershell
# 1. multi-line check (catches the literal-\n bug)
foreach ($f in Get-ChildItem script/Core/Runtime*.lua) {
    "{0}: {1} lines" -f $f.Name, (Get-Content $f | Measure-Object -Line).Lines
}
# 2. syntax/type check once the Luau CLI is installed (Phase 5)
luau-analyze script/Core/Runtime.lua script/Core/Runtime_*.lua
# 3. stub loader dry-run: every Runtime_* spec must return a table with a Start function
```

**D. Regression guard:** add a tiny `tests/TestModules.lua` assertion that loads each
`Runtime_*` file's source and fails if it has fewer than 2 physical lines or does not
contain `Start = function` — this permanently prevents the escaped-`\n` bug from
recurring.

---

## 1. Step 2 completion — Module Config System

1. In `Init.lua`, add a `loadModuleConfig()` helper that fetches `ModuleConfig.lua`
   (local: `require`; remote: `HttpGet`), validates `START_ORDER`, and returns it.
2. Call it **before** computing `START_ORDER`; fall back to the inline `MODULES` on failure.
3. Add `Core/Runtime_Config.lua`, `Runtime_Layers.lua`, `Runtime_Services.lua`,
   `Runtime_Utilities.lua`, `Runtime_Constants.lua` to the fallback array.
4. Add `ModuleConfig.lua` to `NON_SPEC_MODULES` so it is never treated as a spec.
5. Update `AI-WALKTHROUGH.md` to document ModuleConfig as the single source of truth.

**Verify:** local Studio path (`loadLocal`) and remote path both start the same modules in
the same order; no "Missing dependency" / "Invalid module" errors in a stub run.

---

## 2. Step 3 audit — Verbose Logging

- Confirm `script/Core/Logger.lua` exists, has INFO/WARN/DEBUG/ERROR levels, and reads
  `CONFIG.VERBOSE_LOGGING`.
- Ensure `CONFIG.VERBOSE_LOGGING` is defined in `Runtime_Config` and persisted in
  `SaveConfig`.
- Add DEBUG/WARN calls to the silent-bail sites called out in the original plan
  (missing `PlayerStats`, missing `InputBindableFunction`, farm-state reasons).
- Document the toggle in `USAGE.md`.

**Verify:** setting `VERBOSE_LOGGING = true` produces `[AIC] DEBUG/WARN` lines; false
suppresses them.

---

## 3. Step 4b — Split `AutoFarming.lua` (1047 lines)

### Constraint
Everything lives inside one `Start(Context)` closure over ~25 locals and the `Feature`
table. A naive split into separate `Start` modules will lose those closures. Use the same
pattern the Runtime split uses: **entry module wires sub-modules that expose functions via
returned tables**, and shared mutable state lives on `AICFeature.S` / `Context`.

### Target layout
```
Features/AutoFarming.lua            -- entry: Update loop, CreateUI, BuildLateUI, wiring
Features/AutoFarming_State.lua      -- SetFarmState, DescribeChase, retreat/idle logic
Features/AutoFarming_Navigation.lua -- ApproachTarget, waypoint/patrol routing, RunGather
Features/AutoFarming_Combat.lua     -- EnsureWeaponDrawn, TryConsumePotion, TryHeal
Features/AutoFarming_Smithing.lua   -- SmithingStep logic
Features/AutoFarming_Mining.lua     -- MiningStep logic
Features/AutoFarming_UI.lua         -- RenderUpdate, CreateToggleContainer, stat helpers
```

### Method (incremental, one file at a time)
1. Extract **pure/stateless** helpers first (`GetPlayerStatValue`, `GetPlayerLevel`,
   `DescribeChase`, `SetFarmState`) — lowest risk, no closure capture.
2. Extract stateful helpers next (`EnsureWeaponDrawn`, `TryConsumePotion`, `TryHeal`,
   `ApproachTarget`, `RunGather`) — pass needed locals as parameters or read from
   `Context` / `AICFeature.S`.
3. Move `RenderUpdate` + UI helpers into `AutoFarming_UI.lua`.
4. Leave the `Feature:Update(dt)` state machine and `CreateUI`/`BuildLateUI` in the entry.
5. Register all new files in `ModuleConfig.START_ORDER` **before** `AutoFarming.lua`, and
   add `AutoFarming.lua`'s `Dependencies` to include them.
6. After each extraction: grep for the moved name to ensure no dangling references; run the
   syntax checker; run the stub harness.

**Do not** change behavior — this is a pure move/refactor. Preserve comments and the
existing `AICFeature.X = function(...) return Feature.X(...) end` compatibility shims.

---

## 4. Step 4c — Split `ProfileManager.lua` (833 lines)

### Constraint
Functions are assigned as `AICProfile.X = function(...)` closures over locals:
`Runtime`, `SaveConfig`, `CONFIG`, `PROFILE_FOLDER/FILE/PINNED_FILE/GLOBAL_FILE`,
`COMPACT_FEATURE_KEYS`, `BasePlaceConfig`, `PlaceConfig`. Shared state must move to
`AICProfile.S` (or a shared `AICProfile.Storage` table) so sub-modules can read it.

### Target layout
```
Core/ProfileManager.lua                  -- entry: wiring + Start order, shared state
Core/ProfileManager_Storage.lua          -- CanUseFileStorage, EnsureProfileFolder,
                                            Read/WriteProfileStore, Pinned, Global files
Core/ProfileManager_Serialization.lua    -- Serialize/Deserialize, MergeConfig,
                                            BuildCompact*, Expand*, AreSerializedValuesEqual
Core/ProfileManager_Creation.lua         -- BuildDefault*, Capture/Apply Settings,
                                            CreateProfile, ApplyDefaultPlaceConfig
Core/ProfileManager_UI.lua               -- profile dropdown / import-export UI
Core/ProfileManager_Global.lua           -- global store, pinned state, migration
```

### Method
1. Move shared locals (`PROFILE_*` paths, `COMPACT_FEATURE_KEYS`, base/place config) onto
   `AICProfile.S` / `AICProfile.Storage` in the entry, before any sub-module runs.
2. Extract in dependency order: Storage → Serialization → Global → Creation → UI.
3. Each sub-module `Start(Context)` defines its `AICProfile.*` functions, reading shared
   state from the entry's tables.
4. Keep `Queue*Save` debounce timers and `Context.Lifetime.OnEnd` hooks in the entry (or
   move them with their owning module and re-register cleanups).
5. Register new files in `ModuleConfig.START_ORDER` **before** `ProfileManager.lua`; add
   them to `ProfileManager`'s `Dependencies`.
6. Re-run grep + syntax check + stub harness after each extraction.

---

## 5. Step 5 — Real testing framework

### Tooling (needed because vanilla Lua can't parse Luau syntax)
- Install the **Luau CLI** (`luau` + `luau-analyze`) from the Roblox/luau GitHub releases,
  or via `cargo install --git https://github.com/Roblox/luau luau`. No Roblox client needed.
- Use `luau-analyze` for syntax + type checking every changed `.lua` file.
- Use `luau` to run the stub harness and unit tests.

### Files
```
tests/StubRoblox.lua        -- game, Instance, task, pcall, readfile/writefile, getgenv,
                               loadstring, Enum, Vector3, CFrame, typeof, etc.
tests/run.lua               -- loads stubs, runs every Test*, prints pass/fail summary,
                               exits non-zero on failure
tests/TestConfig.lua        -- NormalizeWaitList / NormalizeJumpList / NormalizeZonePairs /
                               CloneTargetList edge cases (nil, negative, >max, dupes, "")
tests/TestSerialization.lua -- SerializeConfigValue/DeserializeConfigValue round-trip,
                               MergeConfig, AreSerializedValuesEqual, IsArrayTable,
                               BuildCompactConfig, ExpandCompactProfile, corrupt JSON
tests/TestStateMachines.lua -- farm-state transitions (IDLE→CHASE→RETREAT→IDLE),
                               retreat thresholds, waypoint-loop reset
```

### Requirements
- Tests target **pure functions only** (no `game`/`workspace` dependence). Where logic is
  still buried in closures, extract the pure part into a sub-module first (ties into
  Steps 3–4).
- `run.lua` must print `✓ name` / `✗ name: expected X got Y` and a final count.
- Add `tests/` to the repo (already have `tests/output/` ignored).

**Verify:** `luau-analyze script/**.lua tests/**.lua` is clean, and `luau tests/run.lua`
prints all pass.

---

## 6. Final verification checklist (no Roblox)

1. `luau-analyze` clean on every file under `script/` and `tests/`.
2. `luau tests/run.lua` → all tests pass.
3. Grep audit:
   - every module in `ModuleConfig.START_ORDER` exists on disk;
   - every `Dependencies` name exists in `START_ORDER`;
   - no references to functions/fields removed by a split;
   - `Runtime_*` files have > 1 physical line (catches the `\n` bug).
4. Stub loader dry-run: load `Init.lua`'s module list against `StubRoblox` and assert all
   specs return `{ Name, Start }` and start without error.
5. Diff review: confirm the splits are moves only (no logic edits) except the documented
   Logger additions.

---

## 7. Order of work / risk

| Phase | Work | Risk | Depends on |
|---|---|---|---|
| 0 | Fix corrupt `Runtime_Utilities`/`Runtime_Constants`, runtime wiring | High (blocker) | — |
| 1 | Finish ModuleConfig wiring | Low | 0 |
| 2 | Audit/finish Logger | Low | 1 |
| 3 | Split AutoFarming (7 files) | Medium | 1 |
| 4 | Split ProfileManager (6 files) | Medium | 1 |
| 5 | Real tests + Luau tooling | Low | 3,4 |

Do **0 → 1** first; the script cannot load until then. Then 3 and 4 can proceed
independently, with 5 last to validate everything.
