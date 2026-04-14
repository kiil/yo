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

Alle `yo`-kommandoer (`run`, `ask`, `continue`, `chat`) accepterer:

- `--provider` — provider: `anthropic`, `openai`, `gemini` (default: `gemini`)
- `--model` — modelnavn (default: `gemini-3.1-flash-lite-preview`)
- `--tools` — preset: `all`, `code`, `web_search`, `none`, `nu`, eller komma-separeret liste
- `--base-url` — base URL for lokale/custom providers (f.eks. ollama)
- `--skills` — skill-mapper (komma-separerede paths)
- `--plugin` — Nushell plugin-paths (kan gentages)
- `--include-path`, `-I` — Nushell include-paths til module resolution (kan gentages)
- `--session` — session-fil (JSONL) at fortsætte fra / gemme i

## Chat shell-escapes

Inde i `yo chat` (og `yo xs chat`) kan du køre shell-kommandoer direkte fra prompten:

- `! <cmd>` — kør `<cmd>` i Nushell og print output lokalt (sendes **ikke** til modellen)
- `!! <cmd>` — kør `<cmd>` og tilføj både kommando og output til samtalen som en user-besked, så modellen ser resultatet i næste tur

Eksempel:

```
you> ! ls
you> !! cat src/main.rs
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
