#!/usr/bin/env python3
"""orgami as an MCP server, so any client that speaks MCP can read the map.

Stdio transport: newline-delimited JSON-RPC 2.0. Every tool shells out to the
same `orgami` CLI the terminal uses, so there is one implementation and no
second copy of the logic to drift.
"""

import json
import os
import subprocess
import sys

ORGAMI = os.environ.get("ORGAMI_BIN") or "orgami"
VERSION = "1.0.0"

TOOLS = [
    {
        "name": "orgami_context",
        "description": (
            "The page for one repository in the mapped organization: language and "
            "framework, the exact commands to run, build and test it, which repos it "
            "calls and is called by, the endpoints it serves, the environment it "
            "reads, where it deploys, which repos it usually changes with, its recent "
            "merged pull requests, and the team's notes on it. Omit `repo` to use the "
            "repository of the current working directory, or to get the organization "
            "overview when outside one. Read this before editing an unfamiliar repo."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "description": "Repository name. Optional."}
            },
        },
    },
    {
        "name": "orgami_search",
        "description": (
            "Search everything orgami knows — repo pages, team notes, recorded "
            "decisions and the organization's conventions — for a word or phrase. "
            "Use when you do not know which repo owns a behavior, or want to check "
            "whether something has already been decided or hit before."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"query": {"type": "string"}},
            "required": ["query"],
        },
    },
    {
        "name": "orgami_notes",
        "description": (
            "Notes the team has recorded: causes found the hard way, gotchas, "
            "constraints that are written down nowhere else. Filter by repo, tag or "
            "free text. Check these before spending time on a problem someone may "
            "already have solved."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string"},
                "tag": {"type": "string"},
                "query": {"type": "string"},
            },
        },
    },
    {
        "name": "orgami_note",
        "description": (
            "Record something durable the team should not have to rediscover — the "
            "real cause of a bug, why an obvious approach does not work here, an "
            "undocumented setup step. ASK THE USER BEFORE CALLING THIS: the note is "
            "shared with their whole team under their name. Never record secrets, "
            "anything already obvious in the code, or anything specific to one session."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "The note, a few sentences, with evidence."},
                "repo": {"type": "string", "description": "Repository it concerns. Defaults to the current checkout."},
                "tags": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["text"],
        },
    },
    {
        "name": "orgami_query",
        "description": (
            "One node of the map and both directions of its edges — a repository, a "
            "host, a deployment tool such as kamal or terraform, or a backing service "
            "such as postgres. Every edge carries the file:line it was found on."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
        },
    },
    {
        "name": "orgami_decisions",
        "description": (
            "Durable decisions mined from merged pull requests: what was adopted or "
            "dropped, what constraint was accepted, what was rejected and why, each "
            "with its pull request. Read before proposing a change that may already "
            "have been decided against."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "orgami_conventions",
        "description": (
            "Every AGENTS.md, CLAUDE.md and CONTRIBUTING.md committed anywhere in the "
            "organization, with the .github repo's copy marked as the org-wide "
            "default. Read before writing code for this organization."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def run(args, stdin=None):
    try:
        p = subprocess.run(
            [ORGAMI] + args,
            capture_output=True,
            text=True,
            timeout=120,
            input=stdin,
        )
    except FileNotFoundError:
        return "orgami is not on PATH. Install it: https://github.com/achevalier-dev/orgami"
    except subprocess.TimeoutExpired:
        return "orgami timed out."
    out = (p.stdout or "").strip()
    err = (p.stderr or "").strip()
    if out:
        return out
    return err or "(no output)"


def company_dir():
    home = os.environ.get("ORGAMI_HOME") or os.path.expanduser("~/.orgami")
    company = os.environ.get("ORGAMI_COMPANY")
    if not company:
        try:
            with open(os.path.join(home, "config.json")) as fh:
                company = json.load(fh).get("default")
        except Exception:
            return None
    if not company:
        return None
    return os.path.join(home, company)


def read_file(*parts):
    d = company_dir()
    if not d:
        return "No orgami company configured. Run `orgami init` or `orgami join`."
    path = os.path.join(d, *parts)
    try:
        with open(path) as fh:
            return fh.read()
    except OSError:
        return f"{path} does not exist yet."


def search(query):
    d = company_dir()
    if not d:
        return "No orgami company configured. Run `orgami init` or `orgami join`."
    hits = []
    for sub in ("map", "notes", "reports"):
        root = os.path.join(d, sub)
        for dirpath, _dirs, files in os.walk(root):
            for name in sorted(files):
                if not name.endswith((".md", ".json")):
                    continue
                path = os.path.join(dirpath, name)
                try:
                    with open(path, errors="replace") as fh:
                        for n, line in enumerate(fh, 1):
                            if query.lower() in line.lower():
                                rel = os.path.relpath(path, d)
                                hits.append(f"{rel}:{n}: {line.strip()[:300]}")
                                if len(hits) >= 60:
                                    return "\n".join(hits) + "\n\n(truncated at 60 matches)"
                except OSError:
                    continue
    return "\n".join(hits) if hits else f"Nothing in the map mentions {query!r}."


def call(name, args):
    if name == "orgami_context":
        repo = args.get("repo")
        return run(["context", repo] if repo else ["context"])
    if name == "orgami_query":
        return run(["query", args.get("name", "")])
    if name == "orgami_notes":
        argv = ["notes"]
        if args.get("repo"):
            argv += ["--repo", args["repo"]]
        if args.get("tag"):
            argv += ["--tag", args["tag"]]
        if args.get("query"):
            argv += [args["query"]]
        return run(argv)
    if name == "orgami_note":
        text = (args.get("text") or "").strip()
        if not text:
            return "Refused: an empty note helps nobody."
        argv = ["note"]
        if args.get("repo"):
            argv += ["--repo", args["repo"]]
        for tag in args.get("tags") or []:
            argv += ["--tag", tag]
        argv += ["--", text]
        return run(argv)
    if name == "orgami_decisions":
        return read_file("map", "DECISIONS.md")
    if name == "orgami_conventions":
        return read_file("map", "CONVENTIONS.md")
    if name == "orgami_search":
        return search(args.get("query", ""))
    return f"Unknown tool: {name}"


def reply(msg_id, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}) + "\n")
    sys.stdout.flush()


def error(msg_id, code, message):
    sys.stdout.write(
        json.dumps({"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}}) + "\n"
    )
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = msg.get("method")
        msg_id = msg.get("id")

        if method == "initialize":
            reply(
                msg_id,
                {
                    "protocolVersion": msg.get("params", {}).get("protocolVersion", "2025-06-18"),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "orgami", "version": VERSION},
                },
            )
        elif method in ("notifications/initialized", "initialized"):
            continue
        elif method == "tools/list":
            reply(msg_id, {"tools": TOOLS})
        elif method == "tools/call":
            params = msg.get("params") or {}
            text = call(params.get("name", ""), params.get("arguments") or {})
            reply(msg_id, {"content": [{"type": "text", "text": text}]})
        elif method == "ping":
            reply(msg_id, {})
        elif msg_id is not None:
            error(msg_id, -32601, f"Method not found: {method}")


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
