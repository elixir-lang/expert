# Installation

The following instructions document how to install Expert after
building from source. Some editors, like Visual Studio Code, have the
ability to automatically install the latest version of Expert for
you.

Expert aims to support Elixir versions `1.15.3` with Erlang `25.0` and later.
**You must compile Expert under the lowest version of Elixir and Erlang that you intend to use in your projects.**

Caveats with the following versions of Elixir and Erlang are documented below:

| Elixir   | Version Range  | Notes    |
| -------- | -------------- | -------- |
| 1.18     | `>= 1.18.0`    |          |
| 1.17     | `>= 1.17.0`    |          |
| 1.16     | `>= 1.16.0`    |          |
| 1.15     | `>= 1.15.3`    | `1.15.0` - `1.15.2` have compiler bugs that prevent Expert from working. |

| Erlang      | Version range    | Notes  |
| ----------- |----------------- | ------ |
|  27         | `>= 27.0`        | Expert will use dramatically more memory due to a bug in Erlang's ETS table compression.  |
|  26         | `>= 26.0.2`      |        |
|  25         | `>= 25.0`        |        |

## Prerequisites
First, Install git LFS by [following these instructions](https://docs.github.com/en/repositories/working-with-files/managing-large-files/installing-git-large-file-storage).

Next, [install `just`](https://github.com/casey/just?tab=readme-ov-file#cross-platform)

Then, clone the git repository. Do this with

```elixir
git clone git@github.com:elixir-lang/expert.git
```

Then change to the expert directory

```shell
cd expert
```

Then fetch expert's dependencies

```shell
just deps forge
just deps engine
just deps expert
```

...and build the project

```shell
just release-local
```

If things complete successfully, you will then have a release in your
`apps/expert/burrito_out` directory. If you see errors, please file a
bug.

For the following examples, assume the absolute path to your Expert
source code is `/my/home/projects/expert` and that you are running an amd64
Linux system. For other systems, replace the `expert_linux_amd64` with the
appropriate binary name.

## Editor-specific setup
1. [Vanilla Emacs with lsp-mode](#vanilla-emacs-with-lsp-mode)
2. [Vanilla Emacs with eglot](#vanilla-emacs-with-eglot)
3. [Visual Studio Code](#visual-studio-code)
4. [neovim](#neovim)
7. [Vim + Vim-LSP](#vim--vim-lsp)
8. [Helix](#helix)
9. [Sublime Text](#sublime-text)

### Vanilla Emacs with lsp-mode
The emacs instructions assume you're using `use-package`, which you
really should be. In your `.emacs.d/init.el` (or wherever you put your
emacs configuration), insert the following code:

```lisp
(use-package lsp-mode
  :ensure t
  :config
  (setq lsp-modeline-code-actions-segments '(count icon name))

  :init
  '(lsp-mode))


(use-package elixir-mode
  :ensure t
  :custom
  (lsp-elixir-server-command '("/my/home/projects/expert/apps/expert/burrito_out/expert_linux_amd64")))
```

Restart emacs, and Lexical should start when you open a file with a
`.ex` extension.


### Vanilla Emacs with eglot

You can add Expert support in the following way:

```emacs-lisp
(with-eval-after-load 'eglot
  (setf (alist-get '(elixir-mode elixir-ts-mode heex-ts-mode)
                   eglot-server-programs
                   nil nil #'equal)
        (if (and (fboundp 'w32-shell-dos-semantics)
                 (w32-shell-dos-semantics))
            '("expert_windows_amd64")
          (eglot-alternatives
           '("expert_linux_amd64" "start_lexical.sh")))))
```

For versions before 30, you can add Eglot support for Lexical in the
following way:

```emacs-lisp
(with-eval-after-load 'eglot
  (setf (alist-get 'elixir-mode eglot-server-programs)
        (if (and (fboundp 'w32-shell-dos-semantics)
                 (w32-shell-dos-semantics))
            '("expert_windows_amd64")
          (eglot-alternatives
           '("expert_linux_amd64" "start_lexical.sh")))))
```

If you're using `elixir-ts-mode` on Emacs 29, you can add a new entry
for Eglot:

```emacs-lisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               `((elixir-ts-mode heex-ts-mode) .
                 ,(if (and (fboundp 'w32-shell-dos-semantics)
                           (w32-shell-dos-semantics))
                      '("expert_windows_amd64")
                    (eglot-alternatives
                     '("expert_linux_amd64" "start_lexical.sh"))))))
```

### Visual Studio Code

Click on the extensions button on the sidebar, then search for
`lexical`, then click `install`.  By default, the extension will automatically
download the latest version of Lexical.

To change to a local executable, go to `Settings -> Extensions -> Lexical` and
type `/my/home/projects/expert/apps/expert/burrito_out/expert_linux_amd64` into the text box in
the `Server: Release path override` section.

### neovim

Expert requires neovim `>= 0.9.0`.

In version `>= 0.9.0`, the key is to append the custom LS
configuration to
[lspconfig](https://github.com/neovim/nvim-lspconfig), so regardless
of whether you are using mason or others, you can use this
configuration below as a reference:

```lua
require('lspconfig').lexical.setup {
  cmd = { "my/home/projects/expert/apps/expert/burrito_out/expert_linux_amd64" },
  root_dir = function(fname)
    return require('lspconfig').util.root_pattern("mix.exs", ".git")(fname) or vim.loop.cwd()
  end,
  filetypes = { "elixir", "eelixir", "heex" },
  -- optional settings
  settings = {}
}
```

### Vim + Vim-LSP

An example of configuring Lexical as the Elixir language server for
[Vim-LSP](https://github.com/prabirshrestha/vim-lsp). Uses the newer vim9script syntax but
can be converted to Vim 8 etc (`:h vim9script`).

```vim9script

# Loading vim-lsp with minpac:
call minpac#add("prabirshrestha/vim-lsp")
# ...or use your package manager of choice/Vim native packages

# Useful for debugging vim-lsp:
# g:lsp_log_verbose = 1
# g:lsp_log_file = expand('~/vim-lsp.log')

# Configure as the elixir language server
if executable("elixir")
    augroup lsp_expert
    autocmd!
    autocmd User lsp_setup call lsp#register_server({ name: "expert", cmd: (server_info) => "{{path_to_expert}}/expert/apps/expert/burrito_out/expert_linux_amd64", allowlist: ["elixir", "eelixir"] })
    autocmd FileType elixir setlocal omnifunc=lsp#complete
    autocmd FileType eelixir setlocal omnifunc=lsp#complete
    augroup end
endif

```

If you use [Vim-LSP-Settings](mattn/vim-lsp-settings) for installing and configuring language servers,
you can use the following flag to disable prompts to install elixir-ls:

```viml
g:lsp_settings_filetype_elixir = ["expert"]

```

For more config, debugging help, or getting vim-lsp to work with ALE, see
[this example vimrc](https://github.com/jHwls/dotfiles/blob/4425a4feef823512d96b92e5fd64feaf442485c9/vimrc#L239).

### Helix

*Note: This configuration is applicable for Helix version 23.09 and above.*

Add the language server to your `~/.config/helix/languages.toml` config.
In the case that the file doesn't exist yet, you can create a new file at this location.

```toml
[language-server.expert]
command = "/my/home/projects/expert/apps/expert/burrito_out/expert_linux_amd64"

[[language]]
name = "elixir"
language-servers = ["expert"]

[[language]]
name = "heex"
language-servers = ["expert"]
```

### Sublime Text

#### Background

Lexical can be used with Sublime Text via the [LSP-Sublime](https://lsp.sublimetext.io/) package, which integrates Language Servers with Sublime Text. If you don't have the LSP-Sublime package installed already, [install it with Package Control](https://packagecontrol.io/packages/LSP).

There is currently no [language server package](https://lsp.sublimetext.io/language_servers/) specifically for Lexical that works with LSP-Sublime so we'll need to create a [custom client configuration](https://lsp.sublimetext.io/client_configuration/).

#### Installation
First, install LSP-Sublime with Package Control if you haven't already.

Next, open up the LSP settings in Sublime. You can do this by invoking the command palette (`ctrl/cmd + shift + p`) and selecting `Preferences: LSP Settings`.

You'll need to add a key called `"clients"` in the top-level `LSP.sublime-settings` JSON dictionary that is as follows:

```json
"clients": {
  "elixir-expert": {
    "enabled": true,
    "command": ["/my/home/projects/expert/apps/expert/burrito_out/expert_linux_amd64", ""],
    "selector": "source.elixir"
  }
}
```
_note: you can name elixir-expert whatever you like, it's just for your own identification_

Upon saving the configuration, LSP-Sublime should enable the new `elixir-expert` LSP server. Go into an Elixir file and you should now see `elixir-expert` in the lower left of the status bar. If not, invoke the command palette and select `LSP: Enable Language Server Globally/In Project` and it should run.
