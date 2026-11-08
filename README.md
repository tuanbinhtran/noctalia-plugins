# tuanbinhtran's Noctalia plugins

Personal catalog of plugins for Noctalia v5; each top-level directory containing a `plugin.toml` is one plugin.

## Plugins

| Plugin | Description | Plugin API |
| --- | --- | --- |
| [Cardwire Manager](cardwire-manager/README.md) | View and switch Cardwire GPU modes from the bar (port of the DMS plugin [jankelemen/cardwire-manager](https://github.com/jankelemen/cardwire-manager)). | 26 |

## Install

Once a plugin is listed in the Noctalia plugin store, install it from Settings → Plugins → Plugin Store, or run:

```sh
noctalia msg plugins enable tuanbinhtran/<plugin>
```

For example, enable Cardwire Manager with `noctalia msg plugins enable tuanbinhtran/cardwire-manager`.

### Run locally (not in the store)

Choose one of these ways to make a plugin available locally.

#### Option A — local checkout as a `path` source (recommended for development, hot reload)

```sh
git clone https://github.com/tuanbinhtran/noctalia-plugins ~/Code/noctalia-plugins
noctalia msg plugins source add tuanbinhtran-dev path ~/Code/noctalia-plugins
noctalia msg plugins list
noctalia msg plugins enable tuanbinhtran/<plugin>
```

For example, enable Cardwire Manager with `noctalia msg plugins enable tuanbinhtran/cardwire-manager`. The source location must be the repository root, not a plugin directory. The equivalent `config.toml` block is:

```toml
[[plugins.source]]
name     = "tuanbinhtran-dev"
kind     = "path"
location = "~/Code/noctalia-plugins"
enabled  = true
```

#### Option B — install straight from GitHub as a `git` source

```sh
noctalia msg plugins source add tuanbinhtran git https://github.com/tuanbinhtran/noctalia-plugins
noctalia msg plugins enable tuanbinhtran/<plugin>
noctalia msg plugins update tuanbinhtran
```

For example, the plugin ID for Cardwire Manager is `tuanbinhtran/cardwire-manager`.

#### Option C — drop-in copy

Copy just the desired plugin directory into Noctalia's local plugins directory, keeping its directory name:

```sh
mkdir -p ~/.local/share/noctalia/plugins
cp -r <plugin> ~/.local/share/noctalia/plugins/
noctalia msg plugins enable tuanbinhtran/<plugin>
```

For Cardwire Manager, use `cardwire-manager` as `<plugin>`. Refresh a drop-in copy manually whenever you update the checkout.

#### Reloading

`.luau` edits hot-reload. A reload that hits a syntax error (for example a half-saved file) stops Noctalia from watching the plugin's `lib/` modules, so later edits are not picked up; check the log and run `noctalia msg config-reload` after fixing it. After editing `plugin.toml`, reload the configuration:

```sh
noctalia msg config-reload
```

#### Remove

Disable the plugin and, if applicable, remove its source or local copy:

```sh
noctalia msg plugins disable tuanbinhtran/<plugin>
noctalia msg plugins source remove tuanbinhtran-dev  # or: tuanbinhtran
rm -r ~/.local/share/noctalia/plugins/<plugin>  # drop-in copy only
```

For existing users: this repository was renamed and GitHub redirects its former URL, but re-add the git source using the new URL. Plugin IDs and widget configuration are unchanged.

## Development

Repository layout:

```text
noctalia-plugins/
├── catalog.toml
├── cardwire-manager/
│   ├── README.md
│   ├── plugin.toml
│   ├── *.luau
│   ├── lib/
│   ├── translations/
│   └── thumbnail.webp
├── tests/
│   ├── harness.luau
│   └── cardwire-manager/
│       ├── cardwire.test.luau
│       └── controller.test.luau
├── scripts/
│   ├── test.sh
│   └── sync-catalog.py
├── LICENSE
└── README.md
```

Run all Luau unit tests, or only one plugin's tests:

```sh
./scripts/test.sh
./scripts/test.sh <plugin>
```

The script uses `$LUAU` if set, else `luau` from `PATH`; otherwise it downloads the pinned Luau 0.745 CLI (`luau-ubuntu.zip`, an x86_64 glibc build) into the gitignored `.tools/` directory, which needs `curl` and `unzip`. On other platforms run `LUAU=/path/to/luau ./scripts/test.sh`. Lint a plugin with:

```sh
noctalia plugins lint <plugin>
```

For optional `luau-lsp` type checking, download Noctalia's API declarations:

```sh
curl -O https://raw.githubusercontent.com/noctalia-dev/official-plugins/main/noctalia.d.luau
```

Run it from the repository root (the file is gitignored) and add `noctalia.d.luau` to luau-lsp's `types.definitionFiles`.

### Adding a plugin

1. Create `<plugin>/plugin.toml` with ID `tuanbinhtran/<plugin>` and the plugin's entries.
2. Add `translations/en.json`, `README.md`, and `thumbnail.webp` in the plugin directory.
3. Add tests under `tests/<plugin>/*.test.luau`; require the shared harness as `../harness` and plugin code as `../../<plugin>/...`.
4. Run `python3 scripts/sync-catalog.py` and commit the regenerated `catalog.toml`.
5. Add a row for the plugin to the root Plugins table.

### Releasing

Bump `version` in the plugin's `plugin.toml`, run `python3 scripts/sync-catalog.py`, and commit the change with a Conventional Commits message. Tag the release `<plugin>/vX.Y.Z`. For store submission, copy only the plugin directory into a community-plugins fork; never copy this repository's `catalog.toml`.

## License

MIT; see [LICENSE](LICENSE). Per-plugin credits are listed in each plugin's README.
