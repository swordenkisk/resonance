# ⚡ Resonance — AI Conversation Tree

> Turn any linear AI chat into a **navigable, branchable knowledge tree**.  
> Inspired by the Megi browser extension — rebuilt as a portable CLI tool.

```
 ██████  ███████ ███████  ██████  ███    ██  █████  ███    ██  ██████ ███████
 ██   ██ ██      ██      ██    ██ ████   ██ ██   ██ ████   ██ ██      ██
 ██████  █████   ███████ ██    ██ ██ ██  ██ ███████ ██ ██  ██ ██      █████
 ██   ██ ██           ██ ██    ██ ██  ██ ██ ██   ██ ██  ██ ██ ██      ██
 ██   ██ ███████ ███████  ██████  ██   ████ ██   ██ ██   ████  ██████ ███████
```

---

## What it does

Linear AI chats force you to scroll through one giant thread.  
**Resonance** organises every question and answer into a tree so you can:

- 🌿 **Branch** from any message to explore alternatives side-by-side
- 🔀 **Move** nodes anywhere with drag-and-drop style re-parenting
- ⭐ **Star & tag** important insights for quick retrieval
- 🔍 **Search** full text across your entire conversation history
- 📁 **Collapse** branches you're done with — they stay, but don't clutter
- 📄 **Export** the whole tree to a clean Markdown document
- 💾 **Save / load** any number of named tree files

---

## Files

| File | Description |
|---|---|
| `resonance.sh` | Universal bash script — works on Linux, macOS, WSL2 |
| `resonance.py` | Python 3.8+ version — works everywhere Python runs |
| `instructions_for_ai_apps.txt` | Full guide for connecting every AI provider |
| `README.md` | This file |

Both files share the **same JSON tree format** (`resonance_tree.json`) and are
fully interoperable — build a tree with the bash script, open it in Python.

---

## Requirements

### Bash version
| Dependency | Install |
|---|---|
| `bash 4+` | `brew install bash` (macOS) |
| `curl` | Pre-installed on most systems |
| `jq` | `sudo apt install jq` / `brew install jq` |

### Python version
- Python 3.8+
- Zero pip installs — uses stdlib only (`urllib`, `json`, `uuid`)

---

## Quick Start — Bash

```bash
# 1. Make executable
chmod +x resonance.sh

# 2. Configure your AI (interactive wizard)
./resonance.sh setup

# 3. Launch interactive REPL
./resonance.sh

# 4. Or ask a one-shot question
./resonance.sh ask "Explain transformer attention mechanisms"
```

## Quick Start — Python

```bash
python3 resonance.py
```

Inside the REPL:
```
resonance [root] › setprovider openai
resonance [root] › setkey sk-...
resonance [root] › setmodel gpt-4o-mini
resonance [root] › ask What is the difference between TCP and UDP?
```

---

## Supported AI Providers

| Provider | Models | Notes |
|---|---|---|
| **OpenAI** | gpt-4o, gpt-4o-mini, o1 | Most widely used |
| **Anthropic** | Claude 3 Haiku/Sonnet/Opus | Best for long reasoning |
| **DeepSeek** | deepseek-chat, deepseek-coder | Very cost-effective |
| **Groq** | Llama3, Mixtral | Fastest inference available |
| **Together** | 100+ open-source models | Great model variety |
| **Ollama** | llama3, mistral, codellama… | 100% local, no API key |
| **xAI** | grok-beta | Grok by xAI |
| **Mistral** | mistral-medium, mistral-large | European AI |
| **Custom** | Any endpoint | LM Studio, vLLM, OpenRouter… |

---

## REPL Commands

```
tree                     Show the full conversation tree
toc                      Table of contents
show <id>                Show full text of a node
ask <text>               Ask AI, add as child of focused node
add <text>               Add user message (no AI call)
note <text>              Add personal annotation
reply <id> <text>        Branch from specific node
focus <id>               Set default parent for add/ask
move <id> <parent-id>    Re-parent a node
collapse <id>            Toggle collapse node's children
star <id>                Toggle star
tag <id> <tag>           Toggle tag
delete <id>              Delete node and subtree
search <query>           Full-text search
stars                    List all starred nodes
stats                    Tree statistics
export [file.md]         Export to Markdown
save / load [file.json]  Persist tree to disk
new [name]               Start fresh tree
config                   Show AI configuration
setup                    Re-run setup wizard
setprovider / setkey / setmodel / seturl
help                     This list
quit                     Save and exit
```

---

## Non-Interactive Usage

```bash
# One-shot question, print answer
./resonance.sh ask "What is entropy?"

# Save the exchange to the tree
./resonance.sh ask "What is entropy?" --save

# Branch from a specific node
./resonance.sh ask "Give me a concrete example" --parent e5f6a1b2 --save

# Pipe stdin to AI
cat paper.txt | ./resonance.sh pipe

# Export tree
./resonance.sh export research_notes.md

# Show stats
./resonance.sh stats
```

---

## Tree File Format

Everything is stored in plain JSON — human-readable, portable, and
processable with any tool:

```json
{
  "name": "My Research",
  "created": "2024-01-15T10:00:00",
  "root": {
    "id": "a1b2c3d4",
    "role": "root",
    "text": "ROOT",
    "children": [
      {
        "id": "e5f6g7h8",
        "role": "user",
        "text": "What is recursion?",
        "starred": true,
        "tags": ["cs", "important"],
        "children": [
          {
            "id": "i9j0k1l2",
            "role": "ai",
            "text": "Recursion is...",
            "children": []
          }
        ]
      }
    ]
  }
}
```

Query it directly with jq:
```bash
jq '[.. | objects | select(.role=="ai")] | length' resonance_tree.json
jq '[.. | objects | select(.starred==true) | .text]' resonance_tree.json
```

---

## Privacy

- All data stays **local** in `resonance_tree.json`
- API keys stored in `~/.resonance_config` with `chmod 600`
- For zero-network usage: use **Ollama** (fully local, no API calls)

---

## Windows

- **Python version**: runs natively with Python 3.8+
- **Bash version**: use WSL2, Git Bash, or MSYS2

---

## Inspiration

Resonance implements the core concepts of the
[Megi browser extension](https://megi.dev) — knowledge-tree organisation
of AI conversations — as a dependency-light, portable CLI tool that works
with **any AI provider**.

---

*resonance.sh requires bash 4+, curl, jq · resonance.py requires Python 3.8+*
