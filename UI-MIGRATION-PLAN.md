# Plan: Migrate the revamped UI (Testing Env/) into the main script

Status: PLAN ONLY - no code has been changed.
Review this document before authorising implementation. Each phase is independently
verifiable and can be rolled back.

## 0. Goal

Replace the current generated script/UI/Utils.lua (built from the old UI/UILib.lua +
compatibility layer) with the new Testing Env/UILib.lua, and rebuild the main
script's UI on top of it using the Testing Env/Example.lua pattern:

- sidebar tabs with icon slots,
- two-column sections,
- Settings tab built entirely through the library's public methods,
- config selector moved into Settings,
- keybind capture that cancels on click-away,
- no walkthrough.

The migration must keep every existing feature, toggle, setting, and saved profile
working (SaveConfig/ProfileManager contract unchanged).

## 1. Current state (what exists)

| Artifact | Role |
|---|---|
| script/UI/UILib.lua | New library copy (untracked, moved from UI Revamp/). |
| Testing Env/UILib.lua | Canonical new library (all recent fixes land here first). |
| Testing Env/Example.lua | Reference usage of the new library. |
| script/UI/Utils.lua | Generated shipped file: old UILib + 4 compatibility parts. Do not hand-edit. |
| script/UI/Components.lua | Binds feature toggles / shared controls to UIRef.* sections. |
| Core/Runtime.lua | Declares UIRef.* tabs/sections and builds the Settings tab via FinishLoading. |
| ModuleConfig.lua / Init.lua | Load order; UI/Utils.lua is a NON_SPEC_MODULE. |

## 2. Key API differences to bridge

| Old (Utils) | New (UILib) | Notes |
### Phase C - Rewrite the compatibility layer
The old layer 1-4 (in REFACTOR-PLAN.md section 6) must be ported to the new library. Deliverables:
1. Utils.new(title, opts) wrapper that calls Library.new{ ... } and stores the window.
2. AddTab/AddSection shims that return objects exposing the positional widget methods modules expect (AddToggle(Name, Opts) or table form).
3. UIRef population: Runtime already calls UIRef.XTab = ...; adapt to new tab/section objects.
4. Re-implement the boot loader progress window on top of the new library (or keep a minimal fallback).
5. Pinned-items panel (UI.Floating) on top of UI.SectionMethods/UI.Theme.
6. Settings tab builder (FinishLoading) using the new public methods.

### Phase D - Regenerate script/UI/Utils.lua
1. Concatenate (UTF-8, no BOM): new UILib.lua (strip trailing return Library) + compatibility parts 1-4, only the last part ending in return Library.
2. Run luau-analyze (or luau-compile) on every file under script/ and tests/.
3. Regenerate and run tests/run-ui-smoke.ps1 against the new Utils.lua.

### Phase E - Adapt Core/Runtime.lua
1. Replace tab/section declarations with new-library calls (Window:AddTab{ Name, Icon, Description }, tab:AddSection{ Side/Full, Title }).
2. Rebuild the Settings tab using the new API (menu scale, anim speed, notifications, theme, cursor, overlays, configs).
3. Wire AddConfigSelector into the Configuration section (already available).
4. Update UIRef aliases used throughout modules.
5. Remove the walkthrough call (already removed in new lib).

### Phase F - Adapt UI/Components.lua
1. BindFeatureToggle(Name, Label, OnChanged, Section) must call the new Section:AddToggle{ Name, Flag, ... }.
2. Dropdown pickers / priority helpers must use new dropdown/listbox API.
3. Keep save keys and defaults unchanged.

### Phase G - Config storage and keybind behaviour
1. Remove any remaining references to the old sidebar config drawer (_popupList config path).
2. Ensure SaveConfig/LoadConfig/LoadConfigs sync the new ConfigSelectors (already in Testing Env).
3. Verify multi-config save/load in Studio.

### Phase H - Keybind cancel behaviour
1. Confirm _listenKey(cb, onCancel) port is included (already in Testing Env).
2. Update every keybind site in modules to pass onCancel restoring the previous key (Toggle bind + AddKeybind already do).

### Phase I - Status icons / sidebar
1. Port AddStatusIcon usage from modules (if any) to the new sidebar bottom grid.
2. Confirm no leftover quick access panel overlaps tabs (already removed holder).

### Phase J - Docs and tests
1. Update script/AI-WALKTHROUGH.md, script/README.md, script/USAGE.md for the new UI.
2. Update tests/UiSmoke.lua to exercise new widgets (config selector, cancel).
3. Update tests/run-ui-smoke.ps1 if generation steps change.

### Phase K - Verification
1. luau-analyze clean on script/ and tests/.
2. luau tests/run.lua -> all pass.
3. tests/run-ui-smoke.ps1 -> builds full menu, clicks tabs/dropdowns/sliders, destroys cleanly.
4. Grep audit: every UIRef.* consumed exists; no references to removed APIs (Walkthrough, old config drawer).
5. In-game smoke test (user-run): open/close, minimize, tabs, settings, configs, keybind capture/cancel.

## 4. Risks and rollback

- High risk: UI/Utils.lua is load-bearing for the boot loader; a broken regeneration prevents the script from starting. Mitigation: keep a backup of the current generated file; verify with smoke test before pushing.
- Medium risk: BindFeatureToggle signature changes could break 70+ modules. Mitigation: keep the shim signature identical; only change internals.
- Medium risk: Settings tab rebuild may miss a control. Mitigation: diff old vs new Settings sections against USAGE.md.
- Rollback: restore script/UI/Utils.lua and script/UI/UILib.lua from git; migration changes are isolated to UI files until Phase E.

## 5. Out of scope

- Uploading/creating real icon assets (placeholders remain rbxassetid://0).
- Changing SaveConfig/ProfileManager schema.
- Web app (web/).

## 6. Open questions for the user

1. Ship via regenerated Utils.lua (Option 1) or switch modules to require UILib.lua directly (Option 2)?
2. Should the boot-loader progress window be ported, or replaced with the new library's loading overlay?
3. Confirm which UIRef tabs/sections must survive vs. can be reorganised.

|---|---|---|
| Utils.new(title, opts) | Library.new{ Title, User, Text, Accent, ... } | Constructor takes a table; returns Window. |
| Window:AddTab(name) | Window:AddTab{ Name, Icon, Description } | Tab is now a table with .AddSection. |
| Section:AddToggle/Slider/... positional | Same method names, but args are tables { Name, Flag, ... } | Already table-based in new lib. |
| UIRef.* sections | Same concept, but created via tab:AddSection{ Side/Full, Title } | Need rebuild in Runtime. |
| Config selector (sidebar bottom) | Section:AddConfigSelector() in Settings | Already implemented. |
| SetWatermark, SetKeybindList, etc. | Same names | Already public. |
| Walkthrough | Removed | Drop all calls. |

## 3. Migration phases

### Phase A - Freeze & baseline
1. Commit/stash the in-progress Testing Env/ work so the migration has a clean base.
2. Run the existing tests/run-ui-smoke.ps1 against the current generated script/UI/Utils.lua to record a green baseline (requires luau).
3. Record the list of every UIRef.* symbol consumed by modules (grep UIRef\.).

### Phase B - Bring the new library into script/UI/
1. Copy Testing Env/UILib.lua -> script/UI/UILib.lua (overwrite the moved copy).
2. Decide the shipping strategy:
   - Option 1 (recommended): keep script/UI/UILib.lua as the source and generate script/UI/Utils.lua from it plus a rewritten compatibility layer.
   - Option 2: ship UILib.lua directly and delete Utils.lua (larger blast radius; modules reference UI.*).
3. Keep UI/Utils.lua as the loader-shipped file for now (Option 1) to avoid touching every module's require/Context.UI.
