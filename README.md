# hedgedoc.nvim

A Neovim Lua plugin to open and edit HedgeDoc notes directly from Neovim.

Features:

- Open a HedgeDoc note by note id or URL.
- Save to HedgeDoc when you run `:w`.
- Poll revision in the background.
- If a remote change is detected:
  - auto-reload if your local buffer is unchanged,
  - switch to read-only and warn if you have unsaved local edits.

## Install (local path)

This repo can live anywhere, but its root must be on Neovim `runtimepath`.

Example using a `bundle` directory:

1. Place or symlink this repo to:

   `~/.config/nvim/bundle/hedgedoc.nvim`

2. Add the path to `runtimepath` in `init.vim`:

```vim
set rtp^=~/.config/nvim/bundle/hedgedoc.nvim
```

## Configure (`init.vim`)

```vim
set rtp^=~/.config/nvim/bundle/hedgedoc.nvim

lua << EOF
require("hedgedoc").setup({
  base_url = "https://your-hedgedoc.example.com",
  token = "YOUR_TOKEN",      -- optional, depending on your auth setup
  poll_interval_ms = 2000,    -- optional, useful while testing
})
EOF
```

Reload Neovim (or `:source $MYVIMRC`) after adding this.

## Getting an auth token

How you get a token depends on your HedgeDoc deployment.

Common cases:

1. Personal access token/JWT exposed by your instance
   - Some deployments provide a token in profile/account settings.
   - Generate/copy that token and set it as `token = "..."`.

2. OIDC/Auth proxy deployment
   - Use the bearer token provided by your identity provider/proxy for API calls.
   - Set it as `token = "..."`.

3. No bearer-token support (session-cookie auth)
   - Use `headers = { Cookie = "<your session cookie>" }` instead of `token`.
   - Example:

```vim
lua << EOF
require("hedgedoc").setup({
  base_url = "https://your-hedgedoc.example.com",
  headers = {
    Cookie = "connect.sid=...",
  },
})
EOF
```

Notes:

- If `token` is set, the plugin sends `Authorization: Bearer <token>`.
- Do not commit tokens/cookies to dotfiles in public repos.
- If unsure what your instance expects, test with `curl` first against your HedgeDoc API.

## Usage

- Open note: `:HedgeDocOpen <note-id-or-url>`
- Save note: `:w` (or `:HedgeDocSave`)

## How module loading works

Neovim resolves `require("hedgedoc")` from runtimepath Lua directories.
With this file layout:

- `lua/hedgedoc/init.lua`

`require("hedgedoc")` works as long as the plugin root is in `runtimepath`.

Verify:

- `:set rtp?` includes your plugin path
- `:lua print(require("hedgedoc"))` loads without errors

## Manual test flow

1. Open the same note in two places (browser + Neovim, or two Neovim instances).
2. In Neovim, with unchanged local buffer (`:echo &modified` is `0`), edit remotely and save.
   - Expected: Neovim auto-reloads to latest revision.
3. In Neovim, make unsaved local edits (`:echo &modified` is `1`), then edit remotely and save.
   - Expected: Neovim warns and sets buffer read-only.

## Commands

- `:HedgeDocOpen {note-id-or-url}`
- `:HedgeDocSave`

## Setup options

Default options:

```lua
{
  base_url = "",
  token = nil,
  headers = {},
  timeout_ms = 10000,
  poll_interval_ms = 10000,
  notify = true,
  filetype = "markdown",
  endpoints = {
    get = "/api/notes/%s",
    put = "/api/notes/%s",
    revision = "/api/notes/%s/revision",
  },
}
```
