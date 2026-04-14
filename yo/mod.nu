# yo - Nushell wrapper around the yoke headless agent harness
# https://github.com/cablehead/yoke

# Default provider/model used when not specified
const PROVIDER = "gemini"
const MODEL = "gemini-3.1-flash-lite-preview"

# --- Shared helpers ---

# Extract final assistant text from role-bearing records
def extract-assistant-text [] {
    $in
    | where { $in | get role? | $in == "assistant" }
    | last
    | get content
    | each {|block| if ($block | get type?) == "text" { $block.text } else { null } }
    | compact
    | str join ""
}

# Render tool output: NUON-aware with truncation
def render-tool-output [output: string] {
    let parsed = try { $output | from nuon } catch { null }
    if $parsed != null {
        print $"(ansi attr_dimmed)│ rendered:(ansi reset)"
        ($parsed | table | into string) | lines | each {|l| print $"(ansi attr_dimmed)(ansi reset)($l)" }
        print $"(ansi attr_dimmed)│ raw:(ansi reset)"
        print $"($parsed | to nuon)"
    } else {
        let olines = $output | lines
        let max_lines = 20
        if ($olines | length) > $max_lines {
            $olines | first $max_lines | each {|l| print $"  (ansi attr_dimmed)│(ansi reset) ($l)" }
            let remaining = ($olines | length) - $max_lines
            print $"  (ansi attr_dimmed)│ ... ($remaining) more lines(ansi reset)"
        } else {
            $olines | each {|l| print $"  (ansi attr_dimmed)│(ansi reset) ($l)" }
        }
    }
}

# Process yoke streaming output, printing deltas and tool events as they arrive
# Input: raw yoke stdout | Returns: {d: bool, ctx: list, turns: int, tok_in: int, tok_out: int}
def render-yoke-stream [] {
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
            if $turns > 1 {
                print $"(ansi attr_dimmed)── turn ($turns) ──(ansi reset)"
            }
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
                | reject ...(["__thought_signature"] | where { |k| $k in ($r | get args? | default {} | columns) })
            print $"(ansi magenta_bold)⚙ ($name)(ansi reset) (ansi attr_dimmed)($tool_args | to nuon)(ansi reset)"
        } else if $rtype == "tool_execution_end" {
            let is_err = $r | get is_error? | default false
            let output = $r | get result?.content? | default []
                | each {|b| if ($b | get type?) == "text" { $b.text } else { null } }
                | compact
                | str join ""
            if $is_err {
                print $"  (ansi red_bold)error:(ansi reset) ($output)"
            } else if ($output | str trim) != "" {
                render-tool-output $output
            }
            print ""
        } else if $rrole == "assistant" and $rtype == "" {
            if $d { print ""; print ""; $d = false }
            let usage = $r | get usage? | default null
            if $usage != null {
                $tok_in = $tok_in + ($usage | get input? | default 0)
                $tok_out = $tok_out + ($usage | get output? | default 0)
                let cols = (term size).columns
                let rows = (term size).rows
                let label = $"in:($tok_in) out:($tok_out) total:($tok_in + $tok_out)"
                let llen = ($label | str length)
                let pad = ($cols - $llen - 1)
                let spaces = ("" | fill -c " " -w $pad)
                print -n (ansi --escape "s")
                print -n (ansi --escape $"($rows);1H")
                print -n (ansi --escape "2K")
                print -n $"(ansi attr_dimmed)($spaces)($label)(ansi reset)"
                print -n (ansi --escape "u")
            }
        }

        if $rrole != "" {
            $ctx = ($ctx | append $r)
        }

        {d: $d, ctx: $ctx, turns: $turns, tok_in: $tok_in, tok_out: $tok_out}
    }
}

# Build extra yoke flags from common options
def yoke-extra-args [
    skills: any
    plugins: list<string>
    include_paths: list<string>
    base_url: any
] {
    mut args = []
    if $base_url != null { $args = ($args | append ["--base-url" $base_url]) }
    if $skills != null { $args = ($args | append ["--skills" $skills]) }
    for p in $plugins { $args = ($args | append ["--plugin" $p]) }
    for i in $include_paths { $args = ($args | append ["-I" $i]) }
    $args
}

# --- xs helpers ---

def yo-xs-addr [] {
    $env | get XS-ADDR? | default ("~/.local/share/cross.stream/store" | path expand)
}

def yo-xs-check [] {
    let addr = yo-xs-addr
    let result = do { xs version $addr } | complete
    if $result.exit_code != 0 {
        error make {msg: $"xs server is not reachable at ($addr). Start it with: xs serve ($addr)"}
    }
}

# Reconstruct JSONL for yoke from xs session frames
def yo-xs-read [name: string] {
    let addr = yo-xs-addr
    xs cat $addr --topic $"yo.($name)" | lines | each {|line|
        let frame = $line | from json
        xs cas $addr $frame.hash
    } | str join "\n"
}

# Append role-bearing records as xs frames
def yo-xs-store [name: string] {
    let addr = yo-xs-addr
    $in | each {|msg|
        let meta = {role: $msg.role} | to json -r
        $msg | to json -r | xs append $addr $"yo.($name)" --meta $meta
    }
}

# List frames for an xs session
def yo-xs-cat [name: string] {
    let addr = yo-xs-addr
    xs cat $addr --topic $"yo.($name)" | lines | each { from json }
}

# Check if an xs session has frames
def yo-xs-has-history [name: string] {
    let addr = yo-xs-addr
    let result = do { xs last $addr $"yo.($name)" } | complete
    $result.exit_code == 0 and ($result.stdout | str trim) != ""
}

# --- File-backed commands ---

# Run a prompt through yoke, returning parsed JSONL records
#
# Examples:
#   yo run "what files are here?"
#   yo run "refactor main.rs" --tools code
export def run [
    prompt: string                          # Prompt to send to the agent
    --provider: string = "gemini"        # Provider: anthropic, openai, gemini
    --model: string = "gemini-3.1-flash-lite-preview"  # Model name
    --tools: string = "all"                 # Tools: all, code, web_search, none, nu, or comma-separated
    --base-url: string                      # Base URL for local/custom providers (e.g. ollama)
    --skills: string                        # Skill directories (comma-separated paths)
    --plugin: list<string> = []             # Nushell plugin paths (repeatable)
    --include-path (-I): list<string> = []  # Nushell include paths for module resolution (repeatable)
    --session: path                         # Session file to continue from (JSONL)
] {
    let extra = yoke-extra-args $skills $plugin $include_path $base_url
    let args = [--provider $provider --model $model --tools $tools ...$extra $prompt]

    if $session != null {
        open --raw $session | ^yoke ...$args | lines | each { from json }
    } else {
        ^yoke ...$args | lines | each { from json }
    }
}

# Ask yoke a question and return only the final assistant text response
#
# Examples:
#   yo ask "what files are here?"
#   yo ask "summarise this code" --tools code
export def ask [
    prompt: string                          # Prompt to send
    --provider: string = "gemini"        # Provider: anthropic, openai, gemini
    --model: string = "gemini-3.1-flash-lite-preview"  # Model name
    --tools: string = "all"                 # Tools preset
    --base-url: string                      # Base URL for local/custom providers (e.g. ollama)
    --skills: string                        # Skill directories (comma-separated paths)
    --plugin: list<string> = []             # Nushell plugin paths (repeatable)
    --include-path (-I): list<string> = []  # Nushell include paths (repeatable)
    --session: path                         # Session file to continue from
] {
    let extra = yoke-extra-args $skills $plugin $include_path $base_url
    let args = [--provider $provider --model $model --tools $tools ...$extra $prompt]
    let state = if $session != null {
        open --raw $session | ^yoke ...$args | render-yoke-stream
    } else {
        ^yoke ...$args | render-yoke-stream
    }
    if $state.d { print "" }
    $state.ctx | extract-assistant-text
}

# Continue an existing session with a new prompt, saving updated session back to the same file
#
# Examples:
#   yo resume session.jsonl "now count them"
export def resume [
    session: path                           # Session JSONL file to read and update
    prompt: string                          # Follow-up prompt
    --provider: string = "gemini"        # Provider: anthropic, openai, gemini
    --model: string = "gemini-3.1-flash-lite-preview"  # Model name
    --tools: string = "all"                 # Tools preset
    --base-url: string                      # Base URL for local/custom providers (e.g. ollama)
    --skills: string                        # Skill directories (comma-separated paths)
    --plugin: list<string> = []             # Nushell plugin paths (repeatable)
    --include-path (-I): list<string> = []  # Nushell include paths (repeatable)
] {
    let extra = yoke-extra-args $skills $plugin $include_path $base_url
    let args = [--provider $provider --model $model --tools $tools ...$extra $prompt]
    let state = open --raw $session | ^yoke ...$args | render-yoke-stream
    if $state.d { print "" }
    let result = $state.ctx
    let new_context = $result | where { $in | get role? | $in != null }
    let existing = open --raw $session | str trim
    let appended = $new_context | each { to json -r } | str join "\n"
    $"($existing)\n($appended)" | save --force $session
    $result
}

# Snapshot a conversation to a JSONL file and pass records through unchanged
#
# Example:
#   yo run "what files are here?" | yo snap session.jsonl
export def snap [
    path: path  # File to write JSONL records to
] {
    let data = $in
    $data | each { to json -r } | str join "\n" | save --force $path
    $data
}

# List available providers and their API key status
export def providers [] {
    ^yoke | lines | each { |line| $line | str trim } | where { $in != "" }
}

# List available models for a provider
export def models [
    --provider: string = "gemini"  # Provider to list models for
] {
    ^yoke --provider $provider | lines | each { |line| $line | str trim } | where { $in != "" }
}

# --- Pipeline filters ---

# Extract only the assistant text from yoke output records
export def text [] {
    $in
    | where { $in | get role? | $in == "assistant" }
    | each {|msg|
        $msg.content
        | each {|block| if ($block | get type?) == "text" { $block.text } else { null } }
        | compact
        | str join ""
    }
    | str join "\n"
}

# Extract only context lines (role field present) — suitable for round-tripping as session input
export def context [] {
    $in | where { $in | get role? | $in != null }
}

# Extract only observation/event lines (type field present)
export def events [] {
    $in | where { $in | get type? | $in != null }
}

# Extract tool execution records from yoke output
export def tools [] {
    $in | where { |r| ($r | get type? ) in ["tool_execution_start" "tool_execution_end"] }
}

# Show token usage from the last assistant turn
export def usage [] {
    $in
    | where { $in | get role? | $in == "assistant" }
    | last
    | get usage?
}

# --- Interactive chat (file-backed) ---

# Interactive turn-based chat TUI
#
# Examples:
#   yo chat
#   yo chat --provider openai --model gpt-4o
export def chat [
    --provider: string = "gemini"                      # Provider: anthropic, openai, gemini
    --model: string = "gemini-3.1-flash-lite-preview"  # Model name
    --tools: string = "all"                            # Tools preset
    --base-url: string                                 # Base URL for local/custom providers (e.g. ollama)
    --skills: string                                   # Skill directories (comma-separated paths)
    --plugin: list<string> = []                        # Nushell plugin paths (repeatable)
    --include-path (-I): list<string> = []             # Nushell include paths (repeatable)
    --session: path                                    # Resume from an existing session file
] {
    let session_file = if $session != null {
        $session
    } else {
        mktemp --suffix .jsonl
    }

    let has_history = $session != null and ($session | path exists) and (open --raw $session | str trim | $in != "")

    if not $has_history {
        let system_msg = {role: "system", content: [
            {type: "text", text: "keep your assistant replies short"}
            {type: "text", text: "do not repeat what is already obvious from the tool call and reply"}
        ]}
        $system_msg | to json -r | save --force $session_file
    }

    print $"(ansi cyan_bold)yo chat(ansi reset) · ($provider)/($model) · tools: ($tools)"
    print $"session: ($session_file)"
    print $"type (ansi yellow_bold)/quit(ansi reset) to exit, (ansi yellow_bold)/save <path>(ansi reset) to copy session"
    print ""

    if $has_history {
        let history = open --raw $session_file | lines | each { from json }
        let last_reply = $history | extract-assistant-text
        print $"(ansi green_bold)assistant(ansi reset) (ansi attr_dimmed)\(resumed)(ansi reset)"
        print $last_reply
        print ""
    }

    let history_file = $session_file | str replace '.jsonl' '.history'
    mut turn = 0

    loop {
        let prompt = input --reedline --history-file $history_file $"(ansi blue_bold)you> (ansi reset)"
        if ($prompt | str trim) == "" { continue }

        if ($prompt | str trim | str starts-with "!!") {
            let cmd = $prompt | str trim | str substring 2..
            print $"(ansi attr_dimmed)!! ($cmd)(ansi reset)"
            let result = ^nu -c $cmd | complete
            let combined = [$result.stdout $result.stderr] | str join "" | str trim
            if $combined != "" { print $combined }
            let user_msg = {role: "user", content: [{type: "text", text: $"!! ($cmd)\n($combined)"}]}
            let existing = open --raw $session_file | str trim
            $"($existing)\n($user_msg | to json -r)" | save --force $session_file
            print ""
            continue
        }

        if ($prompt | str trim | str starts-with "!") {
            let cmd = $prompt | str trim | str substring 1..
            print $"(ansi attr_dimmed)! ($cmd)(ansi reset)"
            let result = ^nu -c $cmd | complete
            if $result.exit_code == 0 {
                if ($result.stdout | str trim) != "" { print ($result.stdout | str trim) }
            } else {
                if ($result.stderr | str trim) != "" {
                    print $"(ansi red_bold)($result.stderr | str trim)(ansi reset)"
                } else if ($result.stdout | str trim) != "" {
                    print ($result.stdout | str trim)
                }
            }
            print ""
            continue
        }

        if ($prompt | str trim) == "/quit" or ($prompt | str trim) == "/exit" {
            print ""
            print $"(ansi attr_dimmed)session saved to ($session_file)(ansi reset)"
            break
        }

        if ($prompt | str trim | str starts-with "/save ") {
            let dest = $prompt | str trim | str replace "/save " "" | str trim
            cp $session_file $dest
            print $"(ansi green)saved to ($dest)(ansi reset)\n"
            continue
        }

        $turn = $turn + 1

        let extra = yoke-extra-args $skills $plugin $include_path $base_url
        let args = [--provider $provider --model $model --tools $tools ...$extra $prompt]
        let state = open --raw $session_file | ^yoke ...$args | render-yoke-stream

        if $state.d { print ""; print "" }

        let existing = open --raw $session_file | str trim
        let appended = $state.ctx | each { to json -r } | str join "\n"
        $"($existing)\n($appended)" | save --force $session_file
    }
}

# --- xs-backed commands ---
# Requires xs (cross.stream) running with $env.XS_ADDR set

# Run a prompt through yoke with xs-backed session storage
#
# Examples:
#   yo xs run "what files are here?"
#   yo xs run "refactor main.rs" --session myproject --tools code
export def "xs run" [
    prompt: string                          # Prompt to send
    --provider: string = "gemini"        # Provider: anthropic, openai, gemini
    --model: string = "gemini-3.1-flash-lite-preview"  # Model name
    --tools: string = "all"                 # Tools preset
    --base-url: string                      # Base URL for local/custom providers (e.g. ollama)
    --skills: string                        # Skill directories (comma-separated paths)
    --plugin: list<string> = []             # Nushell plugin paths (repeatable)
    --include-path (-I): list<string> = []  # Nushell include paths (repeatable)
    --session: string                       # Session name (auto-generated if omitted)
] {
    yo-xs-check
    let name = if $session != null { $session } else { xs scru128 }
    let extra = yoke-extra-args $skills $plugin $include_path $base_url
    let args = [--provider $provider --model $model --tools $tools ...$extra $prompt]

    let context = yo-xs-read $name
    let state = if ($context | str trim) != "" {
        $context | ^yoke ...$args | render-yoke-stream
    } else {
        ^yoke ...$args | render-yoke-stream
    }
    if $state.d { print "" }
    $state.ctx | yo-xs-store $name
    $state.ctx
}

# Ask yoke via xs and return only the final assistant text
#
# Examples:
#   yo xs ask "what is WASM?"
#   yo xs ask "summarise" --session myproject
export def "xs ask" [
    prompt: string                          # Prompt to send
    --provider: string = "gemini"        # Provider: anthropic, openai, gemini
    --model: string = "gemini-3.1-flash-lite-preview"  # Model name
    --tools: string = "all"                 # Tools preset
    --base-url: string                      # Base URL for local/custom providers (e.g. ollama)
    --skills: string                        # Skill directories (comma-separated paths)
    --plugin: list<string> = []             # Nushell plugin paths (repeatable)
    --include-path (-I): list<string> = []  # Nushell include paths (repeatable)
    --session: string                       # Session name (auto-generated if omitted)
] {
    yo-xs-check
    let name = if $session != null { $session } else { xs scru128 }
    let extra = yoke-extra-args $skills $plugin $include_path $base_url
    let args = [--provider $provider --model $model --tools $tools ...$extra $prompt]
    let context = yo-xs-read $name
    let state = if ($context | str trim) != "" {
        $context | ^yoke ...$args | render-yoke-stream
    } else {
        ^yoke ...$args | render-yoke-stream
    }
    if $state.d { print "" }
    $state.ctx | yo-xs-store $name
    $state.ctx | extract-assistant-text
}

# List yo sessions stored in xs
#
# Example:
#   yo xs ls
export def "xs ls" [] {
    yo-xs-check
    let addr = yo-xs-addr
    xs cat $addr | lines | each { from json }
    | where { $in.topic | str starts-with "yo." }
    | group-by topic
    | items {|topic, frames|
        let name = $topic | str replace "yo." ""
        let last_frame = $frames | last
        {name: $name, frames: ($frames | length), last_id: $last_frame.id, last_role: ($last_frame.meta | get role? | default "")}
    }
    | sort-by name
}

# Show conversation log for an xs session
#
# Example:
#   yo xs log myproject
export def "xs log" [
    name: string   # Session name
    --last (-n): int  # Show only last N messages
] {
    yo-xs-check
    let addr = yo-xs-addr
    let frames = yo-xs-cat $name
    let frames = if $last != null { $frames | last $last } else { $frames }
    $frames | each {|frame|
        let content = xs cas $addr $frame.hash | from json
        let text = if ($content | get content?) != null {
            $content.content
            | each {|b| if ($b | get type?) == "text" { $b.text } else { null } }
            | compact
            | str join ""
        } else { "" }
        {id: $frame.id, role: ($content | get role? | default ""), text: ($text | str substring 0..200)}
    }
}

# Interactive chat TUI backed by xs
#
# Examples:
#   yo xs chat
#   yo xs chat --session myproject
#   yo xs chat --provider openai --model gpt-4o
export def "xs chat" [
    --provider: string = "gemini"                      # Provider: anthropic, openai, gemini
    --model: string = "gemini-3.1-flash-lite-preview"  # Model name
    --tools: string = "all"                            # Tools preset
    --base-url: string                                 # Base URL for local/custom providers (e.g. ollama)
    --skills: string                                   # Skill directories (comma-separated paths)
    --plugin: list<string> = []                        # Nushell plugin paths (repeatable)
    --include-path (-I): list<string> = []             # Nushell include paths (repeatable)
    --session: string                                  # Session name (auto-generated if omitted)
] {
    yo-xs-check
    let name = if $session != null { $session } else { xs scru128 }
    let has_history = yo-xs-has-history $name

    if not $has_history {
        let system_msg = {role: "system", content: [
            {type: "text", text: "keep your assistant replies short"}
            {type: "text", text: "do not repeat what is already obvious from the tool call and reply"}
        ]}
        let meta = {role: "system"} | to json -r
        $system_msg | to json -r | xs append (yo-xs-addr) $"yo.($name)" --meta $meta
    }

    print $"(ansi cyan_bold)yo xs chat(ansi reset) · ($provider)/($model) · tools: ($tools)"
    print $"session: (ansi cyan)($name)(ansi reset)"
    print $"type (ansi yellow_bold)/quit(ansi reset) to exit, (ansi yellow_bold)/export <path>(ansi reset) to save JSONL"
    print ""

    if $has_history {
        let frames = yo-xs-cat $name
        let last_msg = $frames | each {|f| xs cas (yo-xs-addr) $f.hash | from json }
            | extract-assistant-text
        print $"(ansi green_bold)assistant(ansi reset) (ansi attr_dimmed)\(resumed)(ansi reset)"
        print $last_msg
        print ""
    }

    let history_file = ($env | get XDG_DATA_HOME? | default ($env.HOME | path join ".local/share"))
        | path join $"yo/($name).history"
    mkdir ($history_file | path dirname)

    mut turn = 0

    loop {
        let prompt = input --reedline --history-file $history_file $"(ansi blue_bold)you> (ansi reset)"
        if ($prompt | str trim) == "" { continue }

        if ($prompt | str trim | str starts-with "!!") {
            let cmd = $prompt | str trim | str substring 2..
            print $"(ansi attr_dimmed)!! ($cmd)(ansi reset)"
            let result = ^nu -c $cmd | complete
            let combined = [$result.stdout $result.stderr] | str join "" | str trim
            if $combined != "" { print $combined }
            let user_msg = {role: "user", content: [{type: "text", text: $"!! ($cmd)\n($combined)"}]}
            [$user_msg] | yo-xs-store $name
            print ""
            continue
        }

        if ($prompt | str trim | str starts-with "!") {
            let cmd = $prompt | str trim | str substring 1..
            print $"(ansi attr_dimmed)! ($cmd)(ansi reset)"
            let result = ^nu -c $cmd | complete
            if $result.exit_code == 0 {
                if ($result.stdout | str trim) != "" { print ($result.stdout | str trim) }
            } else {
                if ($result.stderr | str trim) != "" {
                    print $"(ansi red_bold)($result.stderr | str trim)(ansi reset)"
                } else if ($result.stdout | str trim) != "" {
                    print ($result.stdout | str trim)
                }
            }
            print ""
            continue
        }

        if ($prompt | str trim) == "/quit" or ($prompt | str trim) == "/exit" {
            print ""
            print $"(ansi attr_dimmed)session: ($name)(ansi reset)"
            break
        }

        if ($prompt | str trim | str starts-with "/export ") {
            let dest = $prompt | str trim | str replace "/export " "" | str trim
            let frames = yo-xs-cat $name
            $frames | each {|f| xs cas (yo-xs-addr) $f.hash } | str join "\n" | save --force $dest
            print $"(ansi green)exported to ($dest)(ansi reset)\n"
            continue
        }

        $turn = $turn + 1

        let extra = yoke-extra-args $skills $plugin $include_path $base_url
        let args = [--provider $provider --model $model --tools $tools ...$extra $prompt]
        let context = yo-xs-read $name
        let state = if ($context | str trim) != "" {
            $context | ^yoke ...$args | render-yoke-stream
        } else {
            ^yoke ...$args | render-yoke-stream
        }

        if $state.d { print ""; print "" }

        $state.ctx | yo-xs-store $name
    }
}

# --- xs agent orchestration ---
# Services, actors, and actions for multi-agent choreography

# Register a yoke agent as an xs service watching a topic
#
# The agent runs yoke on each frame arriving at the watched topic.
# Results are stored as <name>.recv frames.
#
# Examples:
#   yo xs spawn reviewer --watch code.changes --tools code
#   yo xs spawn translator --watch articles.new --provider openai --model gpt-4o --tools none
export def "xs spawn" [
    name: string                                # Service name
    --watch: string                             # Topic to watch for input
    --provider: string = "gemini"
    --model: string = "gemini-3.1-flash-lite-preview"
    --tools: string = "all"
    --base-url: string                          # Base URL for local/custom providers (e.g. ollama)
    --skills: string                            # Skill directories (comma-separated paths)
    --plugin: list<string> = []                 # Nushell plugin paths (repeatable)
    --include-path (-I): list<string> = []      # Nushell include paths (repeatable)
    --system: string                            # Optional system prompt prepended to each call
] {
    yo-xs-check
    let addr = yo-xs-addr
    let extra = yoke-extra-args $skills $plugin $include_path $base_url | each {|a| $"\"($a)\""} | str join " "
    let script = if $system != null {
        '{
  run: {||
    .cat -f --topic "__WATCH__" | each {|frame|
      let prompt = .cas $frame.hash
      let sys = {role: "system", content: [{type: "text", text: "__SYSTEM__"}]} | to json -r
      $"($sys)\n($prompt)" | ^yoke --provider __PROVIDER__ --model __MODEL__ --tools __TOOLS__ __EXTRA__
    }
  }
  return_options: { suffix: ".recv", target: "cas" }
}'
        | str replace __SYSTEM__ $system
    } else {
        '{
  run: {||
    .cat -f --topic "__WATCH__" | each {|frame|
      let prompt = .cas $frame.hash
      $prompt | ^yoke --provider __PROVIDER__ --model __MODEL__ --tools __TOOLS__ __EXTRA__
    }
  }
  return_options: { suffix: ".recv", target: "cas" }
}'
    }
    let script = $script
        | str replace __WATCH__ $watch
        | str replace __PROVIDER__ $provider
        | str replace __MODEL__ $model
        | str replace __TOOLS__ $tools
        | str replace __EXTRA__ $extra

    $script | xs append $addr $"($name).spawn"
}

# Define a yoke agent as an on-demand xs action
#
# The action runs yoke on the content of each .call frame.
# Results appear as <name>.response frames. Stateless and parallel-safe.
#
# Examples:
#   yo xs define summarizer --tools none
#   yo xs define coder --provider anthropic --model claude-sonnet-4-20250514 --tools code
export def "xs define" [
    name: string                                # Action name
    --provider: string = "gemini"
    --model: string = "gemini-3.1-flash-lite-preview"
    --tools: string = "all"
    --base-url: string                          # Base URL for local/custom providers (e.g. ollama)
    --skills: string                            # Skill directories (comma-separated paths)
    --plugin: list<string> = []                 # Nushell plugin paths (repeatable)
    --include-path (-I): list<string> = []      # Nushell include paths (repeatable)
    --system: string                            # Optional system prompt
] {
    yo-xs-check
    let addr = yo-xs-addr
    let extra = yoke-extra-args $skills $plugin $include_path $base_url | each {|a| $"\"($a)\""} | str join " "
    let script = if $system != null {
        '{
  run: {|frame|
    let prompt = if ($frame.hash != null) { .cas $frame.hash } else { "" }
    let sys = {role: "system", content: [{type: "text", text: "__SYSTEM__"}]} | to json -r
    $"($sys)\n($prompt)" | ^yoke --provider __PROVIDER__ --model __MODEL__ --tools __TOOLS__ __EXTRA__
  }
  return_options: { suffix: ".response", target: "cas" }
}'
        | str replace __SYSTEM__ $system
    } else {
        '{
  run: {|frame|
    let prompt = if ($frame.hash != null) { .cas $frame.hash } else { "" }
    $prompt | ^yoke --provider __PROVIDER__ --model __MODEL__ --tools __TOOLS__ __EXTRA__
  }
  return_options: { suffix: ".response", target: "cas" }
}'
    }
    let script = $script
        | str replace __PROVIDER__ $provider
        | str replace __MODEL__ $model
        | str replace __TOOLS__ $tools
        | str replace __EXTRA__ $extra

    let result = $script | xs append $addr $"($name).define" | from json

    print $"(ansi green_bold)✓ action defined(ansi reset) (ansi cyan)($name)(ansi reset)"
    print $"(ansi attr_dimmed)  provider:(ansi reset) ($provider)"
    print $"(ansi attr_dimmed)  model:(ansi reset)    ($model)"
    print $"(ansi attr_dimmed)  tools:(ansi reset)     ($tools)"
    if $system != null {
        let sys_preview = if ($system | str length) > 60 {
            $"($system | str substring 0..60)..."
        } else {
            $system
        }
        print $"(ansi attr_dimmed)  system:(ansi reset)    \"($sys_preview)\""
    }
    print $"(ansi attr_dimmed)  id:(ansi reset)       ($result.id)"
    print $"(ansi attr_dimmed)  hash:(ansi reset)      ($result.hash)"
}

# Invoke a defined xs action with a prompt
#
# Examples:
#   "summarize this document" | yo xs call summarizer
#   "fix the bug in main.rs" | yo xs call coder
export def "xs call" [
    name: string   # Action name to invoke
] {
    yo-xs-check
    let addr = yo-xs-addr
    $in | xs append $addr $"($name).call"
}

# Wire one agent's output to another agent's input via an xs actor
#
# Creates an actor that watches the source topic and feeds each frame
# as a .call to the target action.
#
# Examples:
#   yo xs pipe --from reviewer.recv --to fixer
#   yo xs pipe --from analyzer.response --to writer --as analysis-pipeline
export def "xs pipe" [
    --from: string    # Source topic to watch (e.g., "reviewer.recv")
    --to: string      # Target action to call (e.g., "fixer")
    --as: string      # Actor name (auto-generated if omitted)
] {
    yo-xs-check
    let addr = yo-xs-addr
    let actor_name = if $as != null { $as } else {
        $"pipe-($from | str replace --all '.' '-')-to-($to)"
    }

    let script = '{
  run: {|frame, state|
    if ($frame.topic == "__FROM__") {
      let content = .cas $frame.hash
      $content | .append "__TO__.call"
      {next: ($state + 1)}
    } else {
      {next: $state}
    }
  }
  initial: 0
  start: "new"
}'
    | str replace __FROM__ $from
    | str replace __TO__ $to

    $script | xs append $addr $"($actor_name).register"
}

# Register a custom choreography actor with a nushell script
#
# The script must evaluate to a record with {run: closure, initial?: any, start?: string}.
# The run closure receives (frame, state) and returns {out?, next?}.
#
# Example:
#   yo xs choreograph myflow '{
#     run: {|frame, state|
#       match $frame.topic {
#         "analyzer.recv" => {
#           .cas $frame.hash | .append writer.call
#           {next: {stage: "writing"}}
#         }
#         "writer.response" => {
#           {out: "done", next: {stage: "idle"}}
#         }
#       }
#     }
#     initial: {stage: "idle"}
#     start: "new"
#   }'
export def "xs choreograph" [
    name: string     # Actor name
    script: string   # Nushell script evaluating to actor config record
] {
    yo-xs-check
    let addr = yo-xs-addr
    $script | xs append $addr $"($name).register"
}

# Stop an xs service or unregister an actor
#
# Examples:
#   yo xs stop reviewer           # terminate service
#   yo xs stop myflow --actor     # unregister actor
export def "xs stop" [
    name: string      # Service or actor name
    --actor           # Unregister as actor instead of terminating service
] {
    yo-xs-check
    let addr = yo-xs-addr
    if $actor {
        null | xs append $addr $"($name).unregister"
    } else {
        null | xs append $addr $"($name).terminate"
    }
}

# Show status of running xs services and actors
#
# Example:
#   yo xs status
export def "xs status" [] {
    yo-xs-check
    let addr = yo-xs-addr
    let frames = xs cat $addr | lines | each { from json }

    let services = $frames
        | where { $in.topic | str ends-with ".running" }
        | each {|f|
            let name = $f.topic | str replace ".running" ""
            {name: $name, type: "service", id: $f.id}
        }

    let actors = $frames
        | where { $in.topic | str ends-with ".active" }
        | each {|f|
            let name = $f.topic | str replace ".active" ""
            {name: $name, type: "actor", id: $f.id}
        }

    let actions = $frames
        | where { $in.topic | str ends-with ".ready" }
        | each {|f|
            let name = $f.topic | str replace ".ready" ""
            {name: $name, type: "action", id: $f.id}
        }

    $services | append $actors | append $actions | sort-by name
}
