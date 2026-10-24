# Automated Industry Complex

The repository has two parts:

| Folder | What it is |
| --- | --- |
| [`script/`](script/README.md) | The Roblox auto-farm written in Luau — loader, modules, UI library and docs. |
| [`web/`](web/README.md) | The web app. Currently a static placeholder; its content and stack are still to be decided. |

## Run the script

The script is loaded from its own folder, so the entry point is `script/Init.lua`:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Enthusiasticzz/Autofarm-Script-Sbor/refs/heads/main/script/Init.lua"))()
```

`script/Init.lua` is the only file loaded by hand. It fetches every module from
`.../main/script/` (relative to `BASE`), so the folder move changed only the
download base — the module paths inside `MODULES` are unchanged.

- **[QUICKSTART.md](script/QUICKSTART.md)** — the four steps that make it fight.
- **[USAGE.md](script/USAGE.md)** — what every feature does.
- **[AI-WALKTHROUGH.md](script/AI-WALKTHROUGH.md)** — how the code is organised.
- **[TODO.md](script/TODO.md)** — the changelog of shipped work.

## Web

Open [`web/index.html`](web/index.html) in a browser, or serve `web/` with any
static server. It is intentionally content-free for now; see
[`web/README.md`](web/README.md).

## Notes

- `Backup-Copy/`, `Others-code/`, `*.zip` and `.freebuff/` are local working
  copies, ignored by git.
- The old top-level paths (`Init.lua`, `UI/`, `Core/`, `Features/`, `Combat/`)
  now live under `script/`.
