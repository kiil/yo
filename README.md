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
