# yo repl - Nushell overlay for in-REPL yoke conversations
#
# Loads as an overlay so a conversation lives in the current shell.
# The full role-bearing context is kept in $env.YO_CTX, runtime
# defaults (provider, model, tools, ...) live in $env.YO_CFG.
#
# Quick start:
#   overlay use yo/repl.nu
#   say "hej, hvad kan du?"
#   say "uddyb det sidste"        # samme som `again ...` - fortsætter samtalen
#   reply                         # seneste assistant-tekst
#   ctx                           # hele konteksten
#   reset                         # nulstil samtalen
#   overlay hide repl             # smid overlayet (og dermed samtalen) væk
#
# Pipeline-venlige varianter:
#   "opsummér dette" | say        # prompt fra pipe
#   reply | save -f out.md        # send sidste svar videre via builtin `save`

# --- Defaults ---

const PROVIDER = "gemini"
const MODEL    = "gemini-3.1-flash-lite-preview"
const TOOLS    = "all"

# --- Internal helpers (not exported) ---

def yo-cfg [] {
    $env | get YO_CFG? | default {
        provider: $PROVIDER
        model: $MODEL
        tools: $TOOLS
        base_url: null
        skills: null
        plugin: []
        include_path: []
        config: null
    }
}

def yo-extra-args [] {
    let c = yo-cfg
    mut args = []
    if $c.base_url != null { $args = ($args | append ["--base-url" $c.base_url]) }
    if $c.skills   != null { $args = ($args | append ["--skills"   $c.skills]) }
    for p in $c.plugin       { $args = ($args | append ["--plugin" $p]) }
    for i in $c.include_path { $args = ($args | append ["-I" $i]) }
    if $c.config   != null { $args = ($args | append ["--config"   $c.config]) }
    $args
}

def yo-assistant-text [] {
    let assistants = $in | where { $in | get role? | $in == "assistant" }
    if ($assistants | is-empty) { return "" }
    $assistants | last | get content
    | each {|b| if ($b | get type?) == "text" { $b.text } else { null } }
    | compact
    | str join ""
}

def yo-render-tool-output [output: string] {
    let parsed = try { $output | from nuon } catch { null }
    if $parsed != null {
        print $"(ansi attr_dimmed)│ rendered:(ansi reset)"
        ($parsed | table | into string) | lines | each {|l|
            print $"(ansi attr_dimmed)(ansi reset)($l)"
        }
        print $"(ansi attr_dimmed)│ raw:(ansi reset)"
        print $"($parsed | to nuon)"
    } else {
        let lines = $output | lines
        let max = 20
        if ($lines | length) > $max {
            $lines | first $max | each {|l| print $"  (ansi attr_dimmed)│(ansi reset) ($l)" }
            print $"  (ansi attr_dimmed)│ ... (($lines | length) - $max) more lines(ansi reset)"
        } else {
            $lines | each {|l| print $"  (ansi attr_dimmed)│(ansi reset) ($l)" }
        }
    }
}

# Renders a streamed yoke run, returning {ctx, tok_in, tok_out}.
def yo-render-stream [] {
    $in | lines | reduce --fold {d: false, ctx: [], turns: 0, tok_in: 0, tok_out: 0} {|line, acc|
        let r = $line | from json
        let rtype = $r | get type? | default ""
        let rrole = $r | get role? | default ""
        mut d = $acc.d
        mut ctx = $acc.ctx
        mut turns = $acc.turns
        mut tok_in = $acc.tok_in
        mut tok_out = $acc.tok_out

        if $rtype == "turn_start" {
            $turns = $turns + 1
            if $turns > 1 { print $"(ansi attr_dimmed)── turn ($turns) ──(ansi reset)" }
        } else if $rtype == "delta" and ($r | get kind?) == "text" {
            if not $d {
                print ""
                print -n $"(ansi green_bold)assistant(ansi reset) "
                $d = true
            }
            print -n ($r | get delta)
        } else if $rtype == "tool_execution_start" {
            if $d { print ""; $d = false }
            let name = $r | get tool_name? | default "tool"
            let tool_args = $r | get args? | default {}
            print $"(ansi magenta_bold)⚙ ($name)(ansi reset) (ansi attr_dimmed)($tool_args | to nuon)(ansi reset)"
        } else if $rtype == "tool_execution_end" {
            let is_err = $r | get is_error? | default false
            let output = $r | get result?.content? | default []
                | each {|b| if ($b | get type?) == "text" { $b.text } else { null } }
                | compact | str join ""
            if $is_err {
                print $"  (ansi red_bold)error:(ansi reset) ($output)"
            } else if ($output | str trim) != "" {
                yo-render-tool-output $output
            }
            print ""
        } else if $rrole == "assistant" and $rtype == "" {
            if $d { print ""; print ""; $d = false }
            let usage = $r | get usage? | default null
            if $usage != null {
                $tok_in = $tok_in + ($usage | get input? | default 0)
                $tok_out = $tok_out + ($usage | get output? | default 0)
            }
        }

        if $rrole != "" { $ctx = ($ctx | append $r) }

        {d: $d, ctx: $ctx, turns: $turns, tok_in: $tok_in, tok_out: $tok_out}
    }
}

# Build prior-context JSONL string from $env.YO_CTX (or "" when empty).
def yo-prior [] {
    let ctx = $env | get YO_CTX? | default []
    if ($ctx | is-empty) { "" } else {
        $ctx | each { to json -r } | str join "\n"
    }
}

# --- Completions ---

# Cached model list per provider. Returns a list of {value, description}.
def yo-models-for [provider: string] {
    let cache = $env | get YO_MODEL_CACHE? | default {}
    let cached = $cache | get -o $provider
    if $cached != null { return $cached }
    let fresh = try {
        ^yoke models --provider $provider
        | lines
        | each {|l| try { $l | from json } catch { null } }
        | compact
        | each {|m| {value: $m.id, description: ($m | get name? | default "")} }
    } catch { [] }
    $fresh
}

# Pull provider from in-progress command line, else from $env.YO_CFG.
def yo-provider-from-context [context: string] {
    let m = $context | parse --regex '--provider\s+(?<p>\S+)' | get -o p.0
    if $m != null and $m != "" { $m } else { (yo-cfg).provider }
}

def yo-complete-model [context: string] {
    yo-models-for (yo-provider-from-context $context)
}

def yo-complete-provider [] {
    [
        {value: "anthropic"}
        {value: "openai"}
        {value: "gemini"}
        {value: "openrouter"}
        {value: "ollama"}
    ]
}

def yo-tools-catalog [] {
    [
        {value: "all",        description: "group: all built-in tools"}
        {value: "code",       description: "group: code-editing tools"}
        {value: "web_search", description: "group: web search"}
        {value: "none",       description: "no tools"}
        {value: "bash",       description: "shell execution"}
        {value: "nu",         description: "nushell execution"}
        {value: "read_file",  description: "read files"}
        {value: "write_file", description: "write files"}
        {value: "edit_file",  description: "edit files"}
        {value: "list_files", description: "list files"}
        {value: "search",     description: "code search (grep/find)"}
    ]
}

# Comma-separated completer for `--tools`.
# Filters out values already typed before the last comma.
def yo-complete-tools-csv [context: string] {
    let last_token = $context | split row " " | last
    let comma_idx = $last_token | str index-of "," --end
    let prefix = if $comma_idx < 0 { "" } else {
        $last_token | str substring 0..($comma_idx + 1)
    }
    let chosen = if $prefix == "" { [] } else {
        $prefix | str trim --right --char "," | split row "," | where { $in != "" }
    }
    yo-tools-catalog
    | where { |t| $t.value not-in $chosen }
    | each { |t| {value: $"($prefix)($t.value)", description: $t.description} }
}

# Space-separated completer for the `tools` command (rest args).
# Filters the catalog by removing any value already present as a word
# in the in-progress command line, so reedline shrinks per pick.
def yo-complete-tools-rest [context: string] {
    let words = $context | split row " " | where { $in != "" }
    yo-tools-catalog | where value not-in $words
}

# --- Commands ---

# Initialize / reset the conversation. Optionally seeds a system prompt.
#
# Examples:
#   reset
#   reset "du svarer kort og på dansk"
export def --env reset [
    system?: string   # Optional system prompt to seed the new context with
] {
    if $system != null {
        $env.YO_CTX = [
            {role: "system", content: [{type: "text", text: $system}]}
        ]
        print $"(ansi attr_dimmed)context reset · system seeded(ansi reset)"
    } else {
        $env.YO_CTX = []
        print $"(ansi attr_dimmed)context reset(ansi reset)"
    }
}

export alias ,. = reset

# Send a prompt, continuing the in-REPL conversation. Stores the new
# context back into $env.YO_CTX. Returns the assistant's reply text.
#
# Prompt may be passed positionally or via pipeline.
#
# Examples:
#   say "hvilke filer er her?"
#   "opsummér" | say
#   say "fortsæt" --tools none
export def --env say [
    --provider: string@yo-complete-provider   # Override provider for this turn
    --model: string@yo-complete-model         # Override model for this turn
    --tools: string@yo-complete-tools-csv  # Override tools preset for this turn
    --quiet (-q)                         # Skip echoing the assistant reply at end
    ...prompt: string                    # Prompt words (omit to read from pipe)
] {
    let piped = $in
    let joined = $prompt | str join " "
    let piped_str = if $piped == null {
        null
    } else if ($piped | describe) == "string" {
        $piped
    } else {
        $piped | to text
    }
    let text = if ($prompt | is-not-empty) and $piped_str != null {
        $"($joined): ($piped_str)"
    } else if ($prompt | is-not-empty) {
        $joined
    } else if $piped_str != null {
        $piped_str
    } else {
        error make {msg: "say: provide a prompt argument or pipe in a string"}
    }

    let cfg = yo-cfg
    let p = if $provider != null { $provider } else { $cfg.provider }
    let m = if $model    != null { $model }    else { $cfg.model }
    let t = if $tools    != null { $tools }    else { $cfg.tools }
    let extra = yo-extra-args
    let args = [--provider $p --model $m --tools $t ...$extra $text]

    let prior = yo-prior
    let state = if $prior == "" {
        ^yoke ...$args | yo-render-stream
    } else {
        $prior | ^yoke ...$args | yo-render-stream
    }
    if $state.d { print "" }

    let new_ctx = ($env | get YO_CTX? | default []) | append $state.ctx
    $env.YO_CTX = $new_ctx

    let reply = $state.ctx | yo-assistant-text
    if $quiet { null } else { $reply }
}

# Alias for `say` — reads more naturally for follow-ups.
#
#   say "hvad er rust?"
#   again "giv et eksempel"
export alias , = say

# Show the full current context (role-bearing records).
export def ctx [] {
    $env | get YO_CTX? | default []
}

export alias ,$$ = ctx

# Show only the role-bearing records as a slim table.
export def turns [] {
    let c = $env | get YO_CTX? | default []
    $c | enumerate | each {|row|
        let r = $row.item
        let txt = $r.content
            | each {|b| if ($b | get type?) == "text" { $b.text } else { null } }
            | compact | str join ""
        {i: $row.index, role: $r.role, text: ($txt | str substring 0..120)}
    }
}

export alias ,$ = turns


# Latest assistant reply as plain text.
export def reply [] {
    $env | get YO_CTX? | default [] | yo-assistant-text
}

export alias ,, = reply

# Extract a fenced codeblock from the latest assistant reply and parse it
# with the matching `from <fmt>` command. Defaults to the first block;
# pass `--index N` to pick another. Format is taken from the fence's
# language tag (```json, ```yaml, ...) and can be overridden with
# `--format`. Use `--raw` to skip parsing and get the block as a string.
# Use `--list` to see all blocks with their language tags.
#
# Examples:
#   grab                       # parse first codeblock from latest reply
#   grab -i 1                  # second codeblock
#   grab --raw                 # raw string, no parsing
#   grab -f yaml               # force yaml even if fence is bare
#   grab --list                # table of {index, lang, preview}
export def grab [
    --index (-i): int = 0     # which codeblock (0 = first)
    --raw                      # return raw string, do not parse
    --format (-f): string      # override format (json, yaml, toml, csv, tsv, nuon, xml, ssv)
    --list (-l)                # list all codeblocks instead of extracting
] {
    let text = reply
    if ($text | str trim | is-empty) {
        error make {msg: "grab: latest reply is empty"}
    }
    let blocks = $text
        | parse --regex '(?s)```(?<lang>[^\n`]*)\n(?<body>.*?)```'
    if ($blocks | is-empty) {
        error make {msg: "grab: no fenced codeblocks in latest reply"}
    }
    if $list {
        return ($blocks | enumerate | each {|row|
            {
                i: $row.index
                lang: ($row.item.lang | str trim)
                preview: ($row.item.body | str substring 0..80 | str replace --all "\n" "⏎ ")
            }
        })
    }
    let n = $blocks | length
    if $index >= $n or $index < 0 {
        error make {msg: $"grab: index ($index) out of range (0..($n - 1))"}
    }
    let block = $blocks | get $index
    let body = $block.body
    if $raw { return $body }
    let lang = $block.lang | str trim | str downcase
    let fmt = if $format != null { $format | str downcase } else { $lang }
    match $fmt {
        "" | "json" => ($body | from json)
        "yaml" | "yml" => ($body | from yaml)
        "toml" => ($body | from toml)
        "csv" => ($body | from csv)
        "tsv" => ($body | from tsv)
        "ssv" => ($body | from ssv)
        "nuon" | "nu" => ($body | from nuon)
        "xml" | "html" => ($body | from xml)
        "ini" => ($body | from ini)
        "url" => ($body | from url)
        _ => {
            # Last-ditch: try json, then nuon, else error with hint.
            let j = try { $body | from json } catch { null }
            if $j != null { return $j }
            let n = try { $body | from nuon } catch { null }
            if $n != null { return $n }
            error make {msg: $"grab: unknown format '($fmt)' — pass --format or --raw"}
        }
    }
}

export alias ,g = grab

# Execute a nushell codeblock from the latest assistant reply. Picks the
# first fenced block tagged ```nu / ```nushell by default; use `--index`
# to pick another, or `--any` to fall back to the first untagged block.
#
# By default the code is loaded into the REPL prompt buffer via
# `commandline edit` so pressing Enter executes it in the *current*
# session (env mutations, overlay changes, and `let` bindings persist).
# Use `--exec` to instead run it in a `nu` subprocess (no scope
# persistence, but works outside an interactive REPL — e.g. in scripts).
# `--print` shows the code without running, `--raw` returns it as a
# string for piping (e.g. `run --raw | pbcopy`).
#
# Examples:
#   run                       # load first ```nu block into REPL buffer
#   run --exec                # run in subprocess instead
#   run -i 1                  # second nushell block
#   run --print               # show code, do not run
#   run --raw | save out.nu
export def run [
    --index (-i): int = 0     # which nushell block (0 = first)
    --any (-a)                 # also accept untagged ``` blocks
    --exec (-x)                # run in `nu` subprocess instead of REPL paste
    --print (-p)               # print the code instead of running
    --raw                      # return code as string (no exec, no print)
] {
    let text = reply
    if ($text | str trim | is-empty) {
        error make {msg: "run: latest reply is empty"}
    }
    let blocks = $text
        | parse --regex '(?s)```(?<lang>[^\n`]*)\n(?<body>.*?)```'
        | each {|b| {lang: ($b.lang | str trim | str downcase), body: $b.body} }
    if ($blocks | is-empty) {
        error make {msg: "run: no fenced codeblocks in latest reply"}
    }
    let nu_tags = ["nu" "nushell"]
    let candidates = if $any {
        $blocks | where { $in.lang in $nu_tags or $in.lang == "" }
    } else {
        $blocks | where { $in.lang in $nu_tags }
    }
    if ($candidates | is-empty) {
        let hint = if $any { "" } else { " (try --any to include untagged blocks)" }
        error make {msg: $"run: no nushell codeblocks in latest reply($hint)"}
    }
    let n = $candidates | length
    if $index >= $n or $index < 0 {
        error make {msg: $"run: index ($index) out of range (0..($n - 1))"}
    }
    let code = $candidates | get $index | get body
    if $raw { return $code }
    if $print {
        print $"(ansi attr_dimmed)── nushell block ──(ansi reset)"
        print $code
        return
    }
    if $exec {
        print $"(ansi attr_dimmed)── running nushell block (subprocess) ──(ansi reset)"
        ^nu --no-newline -c $code
        return
    }
    # Default: drop the code into the reedline prompt buffer. The user
    # presses Enter to execute it in the current REPL scope.
    try {
        commandline edit --replace $code
        print $"(ansi attr_dimmed)── pasted into prompt · press Enter to run ──(ansi reset)"
    } catch {
        # Not in an interactive reedline session — fall back to subprocess.
        print $"(ansi attr_dimmed)── no reedline · running in subprocess ──(ansi reset)"
        ^nu --no-newline -c $code
    }
}

export alias ,r = run

# Drop the last user/assistant exchange (best-effort: walks back from
# the tail until it has popped one assistant block).
export def --env pop [] {
    mut c = $env | get YO_CTX? | default []
    if ($c | is-empty) {
        print "context already empty"; return
    }
    # Walk back removing trailing tool/system noise then the assistant
    # turn, then the matching user turn.
    while not ($c | is-empty) and (($c | last | get role?) != "assistant") {
        $c = ($c | drop 1)
    }
    if not ($c | is-empty) { $c = ($c | drop 1) }
    while not ($c | is-empty) and (($c | last | get role?) != "user") {
        $c = ($c | drop 1)
    }
    if not ($c | is-empty) { $c = ($c | drop 1) }
    $env.YO_CTX = $c
    print $"(ansi attr_dimmed)popped · ($c | length) records remain(ansi reset)"
}
export alias ,- = pop

# Snapshot the current context to a JSONL file (yoke-compatible).
#
#   snap session.jsonl
export def snap [path: path] {
    let c = $env | get YO_CTX? | default []
    if ($c | is-empty) { error make {msg: "snap: context is empty"} }
    $c | each { to json -r } | str join "\n" | save --force $path
    print $"(ansi green)snapped ($c | length) records → ($path)(ansi reset)"
}

export alias ,> = snap

# Load a JSONL session file into the REPL context, replacing it.
#
#   restore session.jsonl
export def --env restore [path: path] {
    let records = open --raw $path | lines | each { from json }
    $env.YO_CTX = ($records | where { $in | get role? | $in != null })
    print $"(ansi attr_dimmed)restored ($env.YO_CTX | length) records from ($path)(ansi reset)"
}

export alias ,< = restore

# Inspect or set the runtime config. With no args, prints the current
# config. With a record, merges it into $env.YO_CFG.
#
# Examples:
#   cfg
#   cfg {provider: "anthropic", model: "claude-sonnet-4-20250514"}
#   cfg {tools: "code"}
export def --env cfg [
    update?: record   # Partial config to merge in
] {
    let current = yo-cfg
    if $update == null {
        $current
    } else {
        $env.YO_CFG = ($current | merge $update)
        $env.YO_CFG
    }
}

export alias ,: = cfg

# Quick model switch.
#
#   model gpt-4o
#   model claude-sonnet-4-20250514 --provider anthropic
export def --env model [
    name: string@yo-complete-model
    --provider: string@yo-complete-provider   # Optionally also switch provider
] {
    let current = yo-cfg
    let updated = if $provider != null {
        $current | merge {model: $name, provider: $provider}
    } else {
        $current | merge {model: $name}
    }
    $env.YO_CFG = $updated
    print $"(ansi attr_dimmed)now: ($updated.provider)/($updated.model) · tools: ($updated.tools)(ansi reset)"
}

export alias ,m = model

# Quick tools switch. Accepts one or more tools/groups space-separated;
# they are joined with commas for yoke. Tab-completion shrinks per pick.
#
#   tools all
#   tools bash read_file search
export def --env tools [...picks: string@yo-complete-tools-rest] {
    if ($picks | is-empty) {
        error make {msg: "tools: provide at least one tool or group"}
    }
    let preset = $picks | str join ","
    let updated = (yo-cfg) | merge {tools: $preset}
    $env.YO_CFG = $updated
    print $"(ansi attr_dimmed)tools: ($updated.tools)(ansi reset)"
}

export alias ,t = tools

# Set, replace, show or clear the system prompt without dropping the rest
# of the conversation. The system record is always kept at the head of
# $env.YO_CTX.
#
# Examples:
#   system "du svarer kort og på dansk"
#   "load this from a file" | system
#   system                  # show current system prompt
#   system --clear          # remove system prompt
export def --env system [
    --clear (-c)           # Remove the current system prompt
    ...prompt: string      # Prompt words (omit to read from pipe or show)
] {
    let piped = $in
    let joined = $prompt | str join " "
    let piped_str = if $piped == null {
        null
    } else if ($piped | describe) == "string" {
        $piped
    } else {
        $piped | to text
    }
    let text = if ($prompt | is-not-empty) { $joined } else { $piped_str }

    let ctx = $env | get YO_CTX? | default []
    let rest = $ctx | where { ($in | get role?) != "system" }

    if $clear {
        $env.YO_CTX = $rest
        print $"(ansi attr_dimmed)system prompt cleared(ansi reset)"
        return
    }

    if $text == null {
        let sys_list = $ctx | where { ($in | get role?) == "system" }
        if ($sys_list | is-empty) {
            print $"(ansi attr_dimmed)no system prompt set(ansi reset)"
            return ""
        }
        return ($sys_list | first | get content
            | each {|b| if ($b | get type?) == "text" { $b.text } else { null } }
            | compact | str join "")
    }

    let sys_record = {role: "system", content: [{type: "text", text: $text}]}
    $env.YO_CTX = ([$sys_record] | append $rest)
    print $"(ansi attr_dimmed)system prompt set · ($text | str length) chars(ansi reset)"
}

export alias ,s = system

# Show a one-line status banner.
export def status [] {
    let c = yo-cfg
    let n = $env | get YO_CTX? | default [] | length
    print $"(ansi cyan_bold)yo(ansi reset) · ($c.provider)/($c.model) · tools: ($c.tools) · ($n) records in $env.YO_CTX"
}

export alias ,? = status

# Right-prompt segment: model + record count from the live overlay state.
export def yo-prompt [] {
    let cfg = $env | get YO_CFG? | default null
    if $cfg == null { return "" }
    let ctx = $env | get YO_CTX? | default []
    let n = $ctx | length
    let tools = $cfg | get tools? | default ""
    let has_sys = ($ctx | any { ($in | get role?) == "system" })
    let sys_seg = if $has_sys { "📜 · " } else { "" }
    $"(ansi cyan)(ansi reset) (ansi attr_dimmed)($cfg.model) · ($n) · ($sys_seg)🔧 ($tools)(ansi reset)"
}

# Banner shown when the overlay is loaded.
export-env {
    $env.YO_CFG = $env | get YO_CFG? | default {
        provider: $PROVIDER
        model: $MODEL
        tools: $TOOLS
        base_url: null
        skills: null
        plugin: []
        include_path: []
        config: null
    }
    $env.YO_CTX = $env | get YO_CTX? | default []

    $env.YO_PROMPT_SAVED_RIGHT = $env | get PROMPT_COMMAND_RIGHT? | default null
    $env.PROMPT_COMMAND_RIGHT = {|| yo-prompt }

    print $"(ansi cyan_bold)yo overlay(ansi reset) loaded · ($env.YO_CFG.provider)/($env.YO_CFG.model) · type (ansi yellow_bold)say ...(ansi reset) to start"
}
