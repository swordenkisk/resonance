#!/usr/bin/env python3
"""
╔══════════════════════════════════════════════════════════════╗
║              RESONANCE  — Conversation Tree CLI              ║
║   Turns linear AI chats into navigable knowledge trees.      ║
║   Works with any AI: OpenAI · Anthropic · DeepSeek · Ollama  ║
╚══════════════════════════════════════════════════════════════╝
"""

import os, sys, json, uuid, textwrap, readline, time
from typing import List, Dict, Optional
from datetime import datetime

# ── Optional live AI support ──────────────────────────────────────────────────
try:
    import urllib.request, urllib.error
    HTTP_OK = True
except ImportError:
    HTTP_OK = False

# ─────────────────────────────────────────────────────────────────────────────
# ANSI colours
# ─────────────────────────────────────────────────────────────────────────────
C = {
    "reset":  "\033[0m",  "bold":   "\033[1m",  "dim":    "\033[2m",
    "cyan":   "\033[96m", "blue":   "\033[94m",  "green":  "\033[92m",
    "yellow": "\033[93m", "red":    "\033[91m",  "purple": "\033[95m",
    "white":  "\033[97m", "grey":   "\033[90m",
}

def c(text, *colors):
    return "".join(C[x] for x in colors) + str(text) + C["reset"]

BANNER = f"""
{C['cyan']}{C['bold']}
 ██████  ███████ ███████  ██████  ███    ██  █████  ███    ██  ██████ ███████
 ██   ██ ██      ██      ██    ██ ████   ██ ██   ██ ████   ██ ██      ██
 ██████  █████   ███████ ██    ██ ██ ██  ██ ███████ ██ ██  ██ ██      █████
 ██   ██ ██           ██ ██    ██ ██  ██ ██ ██   ██ ██  ██ ██ ██      ██
 ██   ██ ███████ ███████  ██████  ██   ████ ██   ██ ██   ████  ██████ ███████
{C['reset']}
{C['grey']} Turn any AI conversation into a navigable knowledge tree.{C['reset']}
"""

# ─────────────────────────────────────────────────────────────────────────────
# Data model
# ─────────────────────────────────────────────────────────────────────────────
MAX_PREVIEW  = 160
FOLD_THRESH  = 600
SAVE_FILE    = "resonance_tree.json"
CONFIG_FILE  = "resonance_config.json"


class Node:
    def __init__(self, role: str, text: str, nid: Optional[str] = None):
        self.id        = nid or str(uuid.uuid4())[:8]
        self.role      = role          # "user" | "ai" | "note"
        self.text      = text
        self.children: List["Node"] = []
        self.collapsed = False
        self.tags: List[str] = []
        self.created   = datetime.now().isoformat(timespec="seconds")
        self.starred   = False

    # ── Serialisation ──────────────────────────────────────────────────
    def to_dict(self) -> Dict:
        return {
            "id": self.id, "role": self.role, "text": self.text,
            "collapsed": self.collapsed, "tags": self.tags,
            "created": self.created, "starred": self.starred,
            "children": [c.to_dict() for c in self.children],
        }

    @staticmethod
    def from_dict(d: Dict) -> "Node":
        n = Node(d.get("role", "user"), d["text"], d["id"])
        n.collapsed = d.get("collapsed", False)
        n.tags      = d.get("tags", [])
        n.created   = d.get("created", "")
        n.starred   = d.get("starred", False)
        n.children  = [Node.from_dict(c) for c in d.get("children", [])]
        return n

    # ── Tree operations ────────────────────────────────────────────────
    def find(self, nid: str) -> Optional["Node"]:
        if self.id == nid:
            return self
        for ch in self.children:
            r = ch.find(nid)
            if r:
                return r
        return None

    def remove_child(self, nid: str) -> Optional["Node"]:
        for i, ch in enumerate(self.children):
            if ch.id == nid:
                return self.children.pop(i)
            r = ch.remove_child(nid)
            if r:
                return r
        return None

    def preview(self, width: int = MAX_PREVIEW) -> str:
        t = self.text.replace("\n", " ").strip()
        return t if len(t) <= width else t[:width] + "…"

    def is_long(self) -> bool:
        return len(self.text) > FOLD_THRESH


class Tree:
    def __init__(self, name: str = "New Conversation"):
        self.root    = Node("root", "ROOT")
        self.name    = name
        self.created = datetime.now().isoformat(timespec="seconds")

    # ── CRUD ───────────────────────────────────────────────────────────
    def add(self, parent_id: str, role: str, text: str) -> "Node":
        parent = self.find(parent_id)
        if not parent:
            raise ValueError(f"Parent {parent_id!r} not found.")
        n = Node(role, text)
        parent.children.append(n)
        return n

    def find(self, nid: str) -> Optional[Node]:
        return self.root if self.root.id == nid else self.root.find(nid)

    def move(self, nid: str, new_parent_id: str) -> bool:
        if nid == self.root.id:
            return False
        node = self.root.remove_child(nid)
        if not node:
            return False
        target = self.find(new_parent_id)
        if not target:
            self.root.children.append(node)   # rollback
            return False
        target.children.append(node)
        return True

    def delete(self, nid: str) -> bool:
        if nid == self.root.id:
            return False
        return self.root.remove_child(nid) is not None

    def toggle_collapse(self, nid: str) -> bool:
        n = self.find(nid)
        if n:
            n.collapsed = not n.collapsed
            return True
        return False

    def toggle_star(self, nid: str) -> bool:
        n = self.find(nid)
        if n:
            n.starred = not n.starred
            return True
        return False

    def tag(self, nid: str, tag: str) -> bool:
        n = self.find(nid)
        if n:
            if tag in n.tags:
                n.tags.remove(tag)
            else:
                n.tags.append(tag)
            return True
        return False

    # ── Outline ────────────────────────────────────────────────────────
    def outline(self) -> List[Dict]:
        items = []
        def walk(node: Node, depth: int):
            items.append({
                "id": node.id, "depth": depth,
                "role": node.role,
                "preview": node.preview(),
                "is_long": node.is_long(),
                "collapsed": node.collapsed,
                "starred": node.starred,
                "tags": node.tags,
                "child_count": len(node.children),
            })
            if not node.collapsed:
                for ch in node.children:
                    walk(ch, depth + 1)
        for ch in self.root.children:
            walk(ch, 0)
        return items

    def search(self, query: str) -> List[Node]:
        results = []
        q = query.lower()
        def walk(node: Node):
            if q in node.text.lower() or q in " ".join(node.tags).lower():
                results.append(node)
            for ch in node.children:
                walk(ch)
        for ch in self.root.children:
            walk(ch)
        return results

    def starred_nodes(self) -> List[Node]:
        results = []
        def walk(node: Node):
            if node.starred:
                results.append(node)
            for ch in node.children:
                walk(ch)
        for ch in self.root.children:
            walk(ch)
        return results

    # ── Serialisation ──────────────────────────────────────────────────
    def to_dict(self) -> Dict:
        return {
            "name": self.name,
            "created": self.created,
            "root": self.root.to_dict(),
        }

    @staticmethod
    def from_dict(d: Dict) -> "Tree":
        t = Tree(d.get("name", "Conversation"))
        t.created = d.get("created", "")
        t.root    = Node.from_dict(d["root"])
        return t

    # ── Stats ──────────────────────────────────────────────────────────
    def stats(self) -> Dict:
        totals = {"user": 0, "ai": 0, "note": 0, "total": 0, "starred": 0}
        def walk(node: Node):
            if node.role != "root":
                totals[node.role] = totals.get(node.role, 0) + 1
                totals["total"]  += 1
                if node.starred:
                    totals["starred"] += 1
            for ch in node.children:
                walk(ch)
        walk(self.root)
        return totals


# ─────────────────────────────────────────────────────────────────────────────
# Persistence
# ─────────────────────────────────────────────────────────────────────────────

def save_tree(tree: Tree, path: str = SAVE_FILE):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(tree.to_dict(), f, ensure_ascii=False, indent=2)

def load_tree(path: str = SAVE_FILE) -> Tree:
    with open(path, "r", encoding="utf-8") as f:
        return Tree.from_dict(json.load(f))

def load_config() -> Dict:
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, "r") as f:
            return json.load(f)
    return {}

def save_config(cfg: Dict):
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)


# ─────────────────────────────────────────────────────────────────────────────
# AI connector  (supports OpenAI-compatible, Anthropic, Ollama)
# ─────────────────────────────────────────────────────────────────────────────

PROVIDERS = {
    "openai":    {"url": "https://api.openai.com/v1/chat/completions",
                  "default_model": "gpt-4o-mini"},
    "deepseek":  {"url": "https://api.deepseek.com/v1/chat/completions",
                  "default_model": "deepseek-chat"},
    "groq":      {"url": "https://api.groq.com/openai/v1/chat/completions",
                  "default_model": "llama3-70b-8192"},
    "together":  {"url": "https://api.together.xyz/v1/chat/completions",
                  "default_model": "mistralai/Mixtral-8x7B-Instruct-v0.1"},
    "anthropic": {"url": "https://api.anthropic.com/v1/messages",
                  "default_model": "claude-3-haiku-20240307"},
    "ollama":    {"url": "http://localhost:11434/api/chat",
                  "default_model": "llama3"},
}


def ask_ai(prompt: str, context: List[Dict], cfg: Dict) -> str:
    """Send prompt + context to the configured AI and return reply text."""
    if not HTTP_OK:
        return "[HTTP not available]"

    provider = cfg.get("provider", "openai")
    api_key  = cfg.get("api_key", "")
    model    = cfg.get("model", PROVIDERS.get(provider, {}).get("default_model", "gpt-4o-mini"))
    endpoint = cfg.get("custom_url") or PROVIDERS.get(provider, {}).get("url", "")

    messages = context + [{"role": "user", "content": prompt}]

    if provider == "anthropic":
        body = json.dumps({
            "model": model,
            "max_tokens": 2048,
            "messages": messages,
        }).encode()
        headers = {
            "Content-Type":      "application/json",
            "x-api-key":         api_key,
            "anthropic-version": "2023-06-01",
        }
    elif provider == "ollama":
        body = json.dumps({
            "model": model,
            "messages": messages,
            "stream": False,
        }).encode()
        headers = {"Content-Type": "application/json"}
    else:
        # OpenAI-compatible
        body = json.dumps({
            "model": model,
            "messages": messages,
            "max_tokens": 2048,
        }).encode()
        headers = {
            "Content-Type":  "application/json",
            "Authorization": f"Bearer {api_key}",
        }

    try:
        req  = urllib.request.Request(endpoint, data=body, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode())

        if provider == "anthropic":
            return data["content"][0]["text"].strip()
        elif provider == "ollama":
            return data.get("message", {}).get("content", "").strip()
        else:
            return data["choices"][0]["message"]["content"].strip()

    except urllib.error.HTTPError as e:
        return f"[HTTP {e.code}] {e.reason}"
    except Exception as e:
        return f"[Error] {e}"


def build_context(tree: Tree, node_id: str, max_turns: int = 8) -> List[Dict]:
    """Walk ancestors of node_id to build a conversation context list."""
    path = []
    def walk(node: Node, target: str, acc: List[Node]) -> bool:
        if node.id == target:
            return True
        for ch in node.children:
            acc.append(ch)
            if walk(ch, target, acc):
                return True
            acc.pop()
        return False

    acc: List[Node] = []
    walk(tree.root, node_id, acc)
    ctx = []
    for n in acc[-max_turns:]:
        if n.role in ("user", "ai"):
            ctx.append({"role": "user" if n.role == "user" else "assistant",
                        "content": n.text})
    return ctx


# ─────────────────────────────────────────────────────────────────────────────
# Terminal rendering
# ─────────────────────────────────────────────────────────────────────────────

ROLE_ICONS = {"user": "❯", "ai": "◆", "note": "✎", "root": "⬡"}
ROLE_COLS  = {"user": "cyan", "ai": "green", "note": "yellow", "root": "grey"}


def render_tree(tree: Tree, focused_id: Optional[str] = None):
    outline = tree.outline()
    if not outline:
        print(c("  (empty — use 'add' to start)", "dim"))
        return

    for item in outline:
        depth     = item["depth"]
        indent    = "    " * depth
        prefix    = "│   " * max(0, depth - 1) + ("├── " if depth > 0 else "")
        icon      = ROLE_ICONS.get(item["role"], "·")
        role_col  = ROLE_COLS.get(item["role"], "white")
        nid       = item["id"]
        star      = c("★ ", "yellow") if item["starred"] else ""
        tags      = (" " + " ".join(c(f"#{t}", "purple") for t in item["tags"])) if item["tags"] else ""
        kids      = c(f" [{item['child_count']}]", "grey") if item["child_count"] else ""
        fold_mark = c(" [+]", "dim") if item["collapsed"] else ""
        long_mark = c(" [long]", "dim") if item["is_long"] else ""
        focused   = c(" ◀", "yellow") if nid == focused_id else ""

        id_part   = c(f"[{nid}]", "grey")
        icon_part = c(icon, role_col, "bold")
        text_part = c(item["preview"], role_col)

        print(f"  {indent}{prefix}{star}{icon_part} {id_part} {text_part}{kids}{fold_mark}{long_mark}{tags}{focused}")


def render_node_full(node: Node):
    role_col = ROLE_COLS.get(node.role, "white")
    icon     = ROLE_ICONS.get(node.role, "·")
    print()
    print(c(f"  {icon} [{node.id}]  {node.role.upper()}", role_col, "bold"))
    print(c(f"  Created: {node.created}", "dim"))
    if node.tags:
        print(c("  Tags: " + ", ".join(f"#{t}" for t in node.tags), "purple"))
    if node.starred:
        print(c("  ★ Starred", "yellow"))
    print()
    # Word-wrap body
    for line in node.text.split("\n"):
        for wl in textwrap.wrap(line, width=90) or [""]:
            print(f"    {wl}")
    print()


def render_stats(tree: Tree):
    s = tree.stats()
    print(c(f"\n  Tree: {tree.name}", "bold"))
    print(c(f"  Created: {tree.created}", "dim"))
    print(f"  User messages : {c(s['user'],  'cyan')}")
    print(f"  AI responses  : {c(s['ai'],    'green')}")
    print(f"  Notes         : {c(s['note'],  'yellow')}")
    print(f"  Total nodes   : {c(s['total'], 'white', 'bold')}")
    print(f"  Starred       : {c(s['starred'], 'yellow')}")
    print()


def render_outline_toc(tree: Tree):
    outline = tree.outline()
    print(c("\n  ── Table of Contents ──", "bold", "blue"))
    for item in outline:
        indent = "  " * item["depth"]
        icon   = ROLE_ICONS.get(item["role"], "·")
        col    = ROLE_COLS.get(item["role"], "white")
        star   = "★ " if item["starred"] else ""
        print(f"  {indent}{c(icon, col)} {c(item['id'], 'grey')}  {star}{item['preview'][:80]}")
    print()


def render_help():
    commands = [
        ("tree",                    "Show the full conversation tree"),
        ("toc",                     "Table of contents (indented outline)"),
        ("show <id>",               "Show full text of a node"),
        ("ask <text>",              "Ask AI, add reply as child of focused node"),
        ("add <text>",              "Add a user message under focused node"),
        ("note <text>",             "Add a personal note under focused node"),
        ("reply <id> <text>",       "Ask AI using <id> as parent context"),
        ("focus <id>",              "Set focused node (default parent for add/ask)"),
        ("move <id> <parent-id>",   "Re-parent a node (drag-and-drop equivalent)"),
        ("collapse <id>",           "Toggle collapse a node's children"),
        ("star <id>",               "Toggle star on a node"),
        ("tag <id> <tag>",          "Toggle a tag on a node"),
        ("delete <id>",             "Delete a node and its subtree"),
        ("search <query>",          "Full-text search across all nodes"),
        ("stars",                   "List all starred nodes"),
        ("stats",                   "Show tree statistics"),
        ("export <file.md>",        "Export tree to Markdown"),
        ("save [file]",             "Save tree to JSON"),
        ("load [file]",             "Load tree from JSON"),
        ("new [name]",              "Start a new tree"),
        ("config",                  "Show / edit AI configuration"),
        ("setprovider <name>",      "Set AI provider (openai/deepseek/anthropic/ollama/groq/together)"),
        ("setkey <key>",            "Set API key"),
        ("setmodel <model>",        "Set model name"),
        ("seturl <url>",            "Set custom API endpoint URL"),
        ("help",                    "Show this help"),
        ("quit / exit",             "Exit Resonance"),
    ]
    print(c("\n  ── Resonance Commands ──", "bold", "cyan"))
    for cmd, desc in commands:
        print(f"  {c(cmd.ljust(28), 'yellow')}  {c(desc, 'dim')}")
    print()


# ─────────────────────────────────────────────────────────────────────────────
# Markdown export
# ─────────────────────────────────────────────────────────────────────────────

def export_markdown(tree: Tree, path: str):
    lines = [f"# {tree.name}\n", f"_Created: {tree.created}_\n\n---\n"]
    def walk(node: Node, depth: int):
        heading = "#" * min(depth + 2, 6)
        icon    = ROLE_ICONS.get(node.role, "·")
        lines.append(f"\n{heading} {icon} `[{node.id}]` ({node.role})\n")
        if node.starred:
            lines.append("⭐ **Starred**\n")
        if node.tags:
            lines.append("Tags: " + ", ".join(f"`#{t}`" for t in node.tags) + "\n")
        lines.append(f"\n{node.text}\n")
        for ch in node.children:
            walk(ch, depth + 1)
    for ch in tree.root.children:
        walk(ch, 0)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(c(f"  Exported to {path}", "green"))


# ─────────────────────────────────────────────────────────────────────────────
# REPL
# ─────────────────────────────────────────────────────────────────────────────

def run_repl():
    print(BANNER)

    # Load or init tree + config
    tree    = load_tree() if os.path.exists(SAVE_FILE) else Tree()
    cfg     = load_config()
    focused = tree.root.id

    def fp():
        fn = tree.find(focused)
        return c(f"[{focused}]", "yellow") if fn else c("[root]", "yellow")

    if not cfg.get("provider"):
        print(c("  ⚙  No AI provider configured. Type 'config' to set one up.", "yellow"))
        print(c("  ⚙  Or use 'add' / 'note' to build your tree manually.\n", "dim"))

    while True:
        try:
            raw = input(c("resonance", "cyan") + c(f" {fp()} ", "dim") + c("› ", "bold")).strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break

        if not raw:
            continue

        parts = raw.split(None, 2)
        cmd   = parts[0].lower()
        arg1  = parts[1] if len(parts) > 1 else ""
        arg2  = parts[2] if len(parts) > 2 else ""

        # ── Quit ──────────────────────────────────────────────────────
        if cmd in ("quit", "exit", "q"):
            save_tree(tree)
            print(c("  Tree saved. Goodbye.", "green"))
            break

        # ── Tree display ──────────────────────────────────────────────
        elif cmd == "tree":
            render_tree(tree, focused)

        elif cmd == "toc":
            render_outline_toc(tree)

        # ── Show node ─────────────────────────────────────────────────
        elif cmd == "show":
            if not arg1:
                print(c("  Usage: show <id>", "red"))
                continue
            n = tree.find(arg1)
            if not n:
                print(c(f"  Node {arg1!r} not found.", "red"))
            else:
                render_node_full(n)

        # ── Focus ─────────────────────────────────────────────────────
        elif cmd == "focus":
            if not arg1:
                focused = tree.root.id
                print(c("  Focused on root.", "dim"))
            elif tree.find(arg1):
                focused = arg1
                print(c(f"  Focused on [{arg1}].", "green"))
            else:
                print(c(f"  Node {arg1!r} not found.", "red"))

        # ── Add user message ──────────────────────────────────────────
        elif cmd == "add":
            text = (arg1 + (" " + arg2 if arg2 else "")).strip()
            if not text:
                print(c("  Usage: add <text>", "red"))
                continue
            try:
                n = tree.add(focused, "user", text)
                focused = n.id
                print(c(f"  Added user node [{n.id}].", "cyan"))
            except ValueError as e:
                print(c(f"  {e}", "red"))

        # ── Add note ──────────────────────────────────────────────────
        elif cmd == "note":
            text = (arg1 + (" " + arg2 if arg2 else "")).strip()
            if not text:
                print(c("  Usage: note <text>", "red"))
                continue
            try:
                n = tree.add(focused, "note", text)
                print(c(f"  Note [{n.id}] added.", "yellow"))
            except ValueError as e:
                print(c(f"  {e}", "red"))

        # ── Ask AI ────────────────────────────────────────────────────
        elif cmd == "ask":
            text = (arg1 + (" " + arg2 if arg2 else "")).strip()
            if not text:
                print(c("  Usage: ask <question>", "red"))
                continue
            if not cfg.get("provider"):
                print(c("  No AI provider set. Run 'config' first.", "red"))
                continue
            try:
                user_node = tree.add(focused, "user", text)
                focused   = user_node.id
                ctx       = build_context(tree, focused)
                print(c("  ◆ Asking AI…", "dim"))
                reply     = ask_ai(text, ctx, cfg)
                ai_node   = tree.add(focused, "ai", reply)
                focused   = ai_node.id
                render_node_full(ai_node)
                save_tree(tree)
            except ValueError as e:
                print(c(f"  {e}", "red"))

        # ── Reply to specific node ────────────────────────────────────
        elif cmd == "reply":
            parent_id = arg1
            text      = arg2.strip()
            if not parent_id or not text:
                print(c("  Usage: reply <parent-id> <text>", "red"))
                continue
            if not tree.find(parent_id):
                print(c(f"  Node {parent_id!r} not found.", "red"))
                continue
            if not cfg.get("provider"):
                print(c("  No AI provider set. Run 'config' first.", "red"))
                continue
            user_node = tree.add(parent_id, "user", text)
            ctx       = build_context(tree, user_node.id)
            print(c("  ◆ Asking AI…", "dim"))
            reply     = ask_ai(text, ctx, cfg)
            ai_node   = tree.add(user_node.id, "ai", reply)
            focused   = ai_node.id
            render_node_full(ai_node)
            save_tree(tree)

        # ── Move node ─────────────────────────────────────────────────
        elif cmd == "move":
            if not arg1 or not arg2:
                print(c("  Usage: move <id> <new-parent-id>", "red"))
                continue
            if tree.move(arg1, arg2.strip()):
                print(c(f"  Moved [{arg1}] → [{arg2.strip()}].", "green"))
                save_tree(tree)
            else:
                print(c("  Move failed. Check IDs.", "red"))

        # ── Delete ────────────────────────────────────────────────────
        elif cmd == "delete":
            if not arg1:
                print(c("  Usage: delete <id>", "red"))
                continue
            confirm = input(c(f"  Delete [{arg1}] and its subtree? [y/N] ", "red")).strip().lower()
            if confirm == "y":
                if tree.delete(arg1):
                    if focused == arg1:
                        focused = tree.root.id
                    print(c(f"  Deleted [{arg1}].", "yellow"))
                    save_tree(tree)
                else:
                    print(c("  Not found.", "red"))

        # ── Collapse ──────────────────────────────────────────────────
        elif cmd == "collapse":
            if not arg1:
                print(c("  Usage: collapse <id>", "red"))
                continue
            if tree.toggle_collapse(arg1):
                n = tree.find(arg1)
                state = "collapsed" if n.collapsed else "expanded"
                print(c(f"  [{arg1}] is now {state}.", "dim"))
            else:
                print(c("  Node not found.", "red"))

        # ── Star ──────────────────────────────────────────────────────
        elif cmd == "star":
            if not arg1:
                print(c("  Usage: star <id>", "red"))
                continue
            if tree.toggle_star(arg1):
                n = tree.find(arg1)
                state = "starred ★" if n.starred else "unstarred"
                print(c(f"  [{arg1}] {state}.", "yellow"))
            else:
                print(c("  Node not found.", "red"))

        # ── Tag ───────────────────────────────────────────────────────
        elif cmd == "tag":
            if not arg1 or not arg2:
                print(c("  Usage: tag <id> <tagname>", "red"))
                continue
            if tree.tag(arg1, arg2.strip().lstrip("#")):
                print(c(f"  Tag #{arg2.strip()} toggled on [{arg1}].", "purple"))
            else:
                print(c("  Node not found.", "red"))

        # ── Search ────────────────────────────────────────────────────
        elif cmd == "search":
            query = (arg1 + (" " + arg2 if arg2 else "")).strip()
            if not query:
                print(c("  Usage: search <query>", "red"))
                continue
            results = tree.search(query)
            if not results:
                print(c(f"  No results for '{query}'.", "dim"))
            else:
                print(c(f"\n  {len(results)} result(s) for '{query}':", "cyan"))
                for r in results:
                    col = ROLE_COLS.get(r.role, "white")
                    print(f"    {c(r.id, 'grey')}  {c(ROLE_ICONS[r.role], col)}  {r.preview(100)}")
            print()

        # ── Starred ───────────────────────────────────────────────────
        elif cmd == "stars":
            nodes = tree.starred_nodes()
            if not nodes:
                print(c("  No starred nodes.", "dim"))
            else:
                print(c(f"\n  ★ Starred nodes ({len(nodes)}):", "yellow"))
                for r in nodes:
                    col = ROLE_COLS.get(r.role, "white")
                    print(f"    {c(r.id, 'grey')}  {c(ROLE_ICONS[r.role], col)}  {r.preview(80)}")
            print()

        # ── Stats ─────────────────────────────────────────────────────
        elif cmd == "stats":
            render_stats(tree)

        # ── Export ────────────────────────────────────────────────────
        elif cmd == "export":
            path = arg1 or "resonance_export.md"
            export_markdown(tree, path)

        # ── Save ──────────────────────────────────────────────────────
        elif cmd == "save":
            path = arg1 or SAVE_FILE
            save_tree(tree, path)
            print(c(f"  Saved to {path}.", "green"))

        # ── Load ──────────────────────────────────────────────────────
        elif cmd == "load":
            path = arg1 or SAVE_FILE
            if not os.path.exists(path):
                print(c(f"  File {path!r} not found.", "red"))
            else:
                tree    = load_tree(path)
                focused = tree.root.id
                print(c(f"  Loaded {tree.name} from {path}.", "green"))

        # ── New tree ──────────────────────────────────────────────────
        elif cmd == "new":
            save_tree(tree)
            name    = (arg1 + (" " + arg2 if arg2 else "")).strip() or "New Conversation"
            tree    = Tree(name)
            focused = tree.root.id
            print(c(f"  New tree '{name}' created.", "green"))

        # ── Config ───────────────────────────────────────────────────
        elif cmd == "config":
            print(c("\n  ── Current Configuration ──", "bold"))
            for k, v in cfg.items():
                val = ("*" * len(v)) if k == "api_key" and v else (v or "(not set)")
                print(f"    {c(k.ljust(16), 'yellow')} {val}")
            print()
            print(c("  Available providers:", "dim"))
            for name, info in PROVIDERS.items():
                mark = c(" ◀ active", "yellow") if name == cfg.get("provider") else ""
                print(f"    {c(name.ljust(12), 'cyan')} {info['default_model']}{mark}")
            print()

        elif cmd == "setprovider":
            if not arg1:
                print(c("  Usage: setprovider <name>", "red"))
            else:
                cfg["provider"] = arg1
                if arg1 in PROVIDERS and "model" not in cfg:
                    cfg["model"] = PROVIDERS[arg1]["default_model"]
                save_config(cfg)
                print(c(f"  Provider set to '{arg1}'.", "green"))

        elif cmd == "setkey":
            if not arg1:
                print(c("  Usage: setkey <api-key>", "red"))
            else:
                cfg["api_key"] = arg1
                save_config(cfg)
                print(c("  API key saved.", "green"))

        elif cmd == "setmodel":
            if not arg1:
                print(c("  Usage: setmodel <model-name>", "red"))
            else:
                cfg["model"] = arg1
                save_config(cfg)
                print(c(f"  Model set to '{arg1}'.", "green"))

        elif cmd == "seturl":
            if not arg1:
                print(c("  Usage: seturl <url>", "red"))
            else:
                cfg["custom_url"] = arg1
                save_config(cfg)
                print(c(f"  Custom URL set to '{arg1}'.", "green"))

        # ── Help ──────────────────────────────────────────────────────
        elif cmd in ("help", "h", "?"):
            render_help()

        else:
            print(c(f"  Unknown command '{cmd}'. Type 'help' for a list.", "dim"))


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    run_repl()
