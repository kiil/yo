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

## yolay — REPL overlay

`yo/yolay.nu` is a Nushell *overlay* that keeps a live conversation inside your current shell. Unlike `use`, an overlay injects commands and env variables into the active scope, so the conversation context (`$env.YO_CTX`) and runtime config (`$env.YO_CFG`) persist between calls until you hide the overlay.

Load it:

```nushell
overlay use yo/yolay.nu          # overlay name becomes `yolay`
overlay use yo/yolay.nu as yo    # or pick a shorter name
overlay list                     # show active overlays
overlay hide yolay               # detach (drops the conversation)
```

Basic conversation:

```nushell
say "hi, what can you do?"
say "elaborate on that"          # continues the same conversation
reply                            # latest assistant text
ctx                              # full role-bearing context
turns                            # slim table of the conversation
reset                            # start a fresh context
reset "you answer briefly"       # reset and seed a system prompt
```

Pipeline-friendly:

```nushell
"summarize this file" | say
open notes.md | say "rewrite as bullet points:"
reply | save -f out.md
```

Editing the conversation:

```nushell
pop                              # drop the last user/assistant exchange
snap session.jsonl               # save current context to JSONL
restore session.jsonl            # load JSONL back into the overlay
system "you answer in English"   # set/replace system prompt (kept at head)
system                           # show current system prompt
system --clear                   # remove system prompt
```

Extracting and executing code from replies:

```nushell
grab                             # parse first fenced codeblock from latest reply
grab -i 1                        # second codeblock
grab --raw                       # raw string, skip parsing
grab -f yaml                     # force a format even if fence is bare
grab --list                      # table of {index, lang, preview}
```

`grab` reads the language tag from the fence (```json, ```yaml, ```toml, ```csv, ```tsv, ```ssv, ```nuon, ```xml, ```ini, ```url, ...) and pipes the body through the matching `from <fmt>` command. Untagged blocks fall back to `from json`, then `from nuon`.

```nushell
run                              # paste first ```nu / ```nushell block into REPL prompt
run -i 1                         # second nushell block
run --any                        # also accept untagged ``` blocks
run --exec                       # run in a `nu` subprocess instead of REPL paste
run --print                      # show the code without running it
run --raw | save out.nu          # return code as string for piping
```

By default `run` loads the code into the reedline prompt buffer via `commandline edit`, so pressing Enter executes it in the *current* session — env mutations, overlay changes, and `let` bindings persist. `--exec` forks a `nu` subprocess instead (no scope persistence, but works in non-interactive contexts).

Background jobs (fire-and-forget turns):

```nushell
bg "summarize the last 10 commits"   # spawns a nushell job, returns job id
"long prompt from pipe" | bg
bg --tools none "think further"
bg-list                              # show pending/finished bg jobs
bg-take 1                            # merge job 1's reply into YO_CTX, print it
bg-take 1 --peek                     # read reply without merging
bg-take 1 --drop                     # also delete the temp files
bg-notify-test                       # sanity-check desktop notifications
```

`bg` snapshots the current conversation, runs `yoke` in a nu job, and writes the streamed JSONL to a temp file. When the job finishes it emits a desktop notification (OSC 9 + OSC 777) and a terminal bell. Because jobs run in their own scope they can't mutate `$env.YO_CTX` directly — call `bg-take <id>` to fold the reply back into the conversation. Job ids restart at 1 each nu session; `bg-take` resolves ties by picking the newest match.

Aliases: `,b` = `bg`, `,bl` = `bg-list`, `,bt` / `,,b` = `bg-take`.

Skills:

```nushell
skills ~/.claude/skills              # set one or more skill directories
skills ~/skills ./project-skills
skills                               # show current skills
skills --clear                       # remove skills config
say "post this to drupal" --skills ~/.claude/skills   # one-shot override
```

When skills are active, `say` / `bg` inject a system note teaching the model that skills are CLI bundles (not tool calls) and upgrade the tools preset to include `read_file` and `nu` if missing. Alias: `,k` = `skills`.

`system --default` loads a built-in knowledge-work / business system prompt without typing it out.

Switching provider, model, and tools on the fly:

```nushell
cfg                              # show current config
cfg {tools: "code"}              # merge a partial update
model claude-sonnet-4-5 --provider anthropic
tools bash read_file search      # space-separated, joined with commas
say "fix the bug" --tools none   # one-shot override for this turn
status                           # one-line banner
```

Short aliases (handy for fast back-and-forth):

| alias | command  |
| ----- | -------- |
| `,`   | `say`    |
| `,,`  | `reply`  |
| `,.`  | `reset`  |
| `,-`  | `pop`    |
| `,g`  | `grab`   |
| `,r`  | `run`    |
| `,?`  | `status` |
| `,:`  | `cfg`    |
| `,m`  | `model`  |
| `,t`  | `tools`  |
| `,k`  | `skills` |
| `,s`  | `system` |
| `,b`  | `bg`     |
| `,bl` | `bg-list`|
| `,bt` | `bg-take`|
| `,$`  | `turns`  |
| `,$$` | `ctx`    |
| `,>`  | `snap`   |
| `,<`  | `restore`|

When the overlay is active, the right-prompt shows the current model, record count, and tools preset.

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
