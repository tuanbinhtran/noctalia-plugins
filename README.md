# tuanbinhtran's Noctalia plugins

Noctalia v5 plugins. Each top-level directory with a `plugin.toml` is one plugin.

| Plugin | Description |
| --- | --- |
| [Cardwire Manager](cardwire-manager/README.md) | View and switch Cardwire GPU modes from the bar. |

## Install

From the store (once listed): Settings → Plugins → Plugin Store.

Run locally (not in the store), add this repo as a source and enable a plugin:

```sh
# git source
noctalia msg plugins source add tuanbinhtran git https://github.com/tuanbinhtran/noctalia-plugins

# or a local checkout (hot-reloads .luau edits)
git clone https://github.com/tuanbinhtran/noctalia-plugins ~/Code/noctalia-plugins
noctalia msg plugins source add tuanbinhtran-dev path ~/Code/noctalia-plugins

noctalia msg plugins enable tuanbinhtran/<plugin>
```

The source location is the repo root, not a plugin directory. If a hot reload hits a syntax error, fix it and run `noctalia msg config-reload`.

## Development

```sh
./scripts/test.sh [plugin]            # Luau tests in tests/<plugin>/
noctalia plugins lint <plugin>
python3 scripts/sync-catalog.py       # regenerate catalog.toml (commit it)
```

New plugin: add `<plugin>/plugin.toml` (id `tuanbinhtran/<plugin>`), tests in `tests/<plugin>/`, regenerate the catalog, add a table row. Release: bump `version`, regenerate the catalog, tag `<plugin>/vX.Y.Z`.

## License

MIT
