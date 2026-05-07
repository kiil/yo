# yo

A Nushell module wrapping the [yoke](https://github.com/cablehead/yoke) headless agent harness — lets you run and interact with AI agents directly from your shell.

## Requirements

- [Nushell](https://www.nushell.sh/)
- [yoke](https://github.com/cablehead/yoke) installed and on your `PATH`

## Usage

```nushell
use yo/mod.nu *
```

## Default Provider

Uses `gemini` with `gemini-3.1-flash-lite-preview` by default. Override per command as needed.

## Features

- Streams assistant responses and tool events as they arrive
- NUON-aware tool output rendering with truncation for long results
- Token usage tracking across multi-turn conversations

## Common flags

All `yo` commands (`run`, `ask`, `continue`, `chat`) accept:

- `--provider` — provider: `anthropic`, `openai`, `gemini` (default: `gemini`)
- `--model` — model name (default: `gemini-3.1-flash-lite-preview`)
- `--tools` — preset: `all`, `code`, `web_search`, `none`, `nu`, or a comma-separated list
- `--base-url` — base URL for local/custom providers (e.g. ollama)
- `--skills` — skill directories (comma-separated paths)
- `--plugin` — Nushell plugin paths (can be repeated)
- `--include-path`, `-I` — Nushell include paths for module resolution (can be repeated)
- `--config` — Nushell config script run once at the start of the agent's nu session (use, def, and env mutations persist for subsequent tool calls)
- `--session` — session file (JSONL) to continue from / save to

## Resuming sessions

`yo resume` continues a prior conversation. The previous context can come from a file or from the pipeline:

```nushell
yo resume "now count them" --session session.jsonl     # from file (writes back)
open session.jsonl | lines | each { from json } | yo resume "now count them"
open --raw session.jsonl | yo resume "now count them"  # raw JSONL string
```

When `--session` is given, the updated context is appended back to that file.

## Chat shell-escapes

Inside `yo chat` (and `yo xs chat`) you can run shell commands directly from the prompt:

- `! <cmd>` — run `<cmd>` in Nushell and print output locally (**not** sent to the model)
- `!! <cmd>` — run `<cmd>` and append both the command and its output to the conversation as a user message, so the model sees the result on the next turn
- `!| <cmd>` — pipe the last assistant reply (available as `$env.YO_LAST`) through `<cmd>` and print the result locally

Example:

```
you> ! ls
you> !! cat src/main.rs
you> !| save -f reply.md
you> !| from json | get items
```

## xs (cross.stream) integration

When [xs](https://github.com/cablehead/xs) is running, `yo` gains persistent, session-backed commands under the `xs` subcommand:

```nushell
yo xs run "what files are here?"            # run a prompt, auto-creates a session
yo xs run "refactor main.rs" --session myproject
yo xs chat --session myproject              # interactive TUI
yo xs ask "summarise" --session myproject   # returns only the final assistant text
yo xs ls                                    # list all yo sessions in the stream
yo xs log myproject                         # show conversation history for a session
```

Agent orchestration:

```nushell
yo xs spawn reviewer --watch code.changes   # register a yoke agent as an xs service
yo xs define summarizer --tools none        # define an on-demand action
"fix the bug in main.rs" | yo xs call coder
yo xs pipe --from reviewer.recv --to fixer  # wire agents together
yo xs status                                # show running services and actors
```

`yo` looks for xs at `$env.XS_ADDR`, falling back to `~/.local/share/cross.stream/store`. Start xs with:

```sh
xs serve ~/.local/share/cross.stream/store
```
