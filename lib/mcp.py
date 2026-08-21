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
import time

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
            "undocumented setup step. Also how one instance of recurring work was done "
            "— one more fetcher, one more endpoint, one more migration — with the "
            "'pattern' tag and a 'topic'; two instances under one topic write that "
            "job's playbook. ASK THE USER BEFORE CALLING THIS: the note is "
            "shared with their whole team under their name. Never record secrets, "
            "anything already obvious in the code, or anything specific to one session."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "The note, a few sentences, with evidence."},
                "repo": {"type": "string", "description": "Repository it concerns. Defaults to the current checkout."},
                "tags": {"type": "array", "items": {"type": "string"}},
                "topic": {
                    "type": "string",
                    "description": (
                        "Only with the 'pattern' tag: the kebab-case name of the recurring "
                        "job this is one instance of, general enough that the next instance "
                        "files under it — 'broken-fetcher', not 'carmax-timeout'."
                    ),
                },
            },
            "required": ["text"],
        },
    },
    {
        "name": "orgami_playbook",
        "description": (
            "How a recurring kind of change is made in one repository — when you are "
            "in this case, what to check first, the steps in order, the traps, and the "
            "check that closes it. Written from the instances the team recorded doing "
            "it, each claim carrying the note or pull request behind it. Read it before "
            "starting a job that has one. With no repo, lists every playbook recorded. "
            "Its prose is the one part of the map a model wrote: the evidence it was "
            "written from is printed underneath, and where they disagree the evidence wins."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string"},
                "topic": {"type": "string"},
            },
        },
    },
    {
        "name": "orgami_query",
        "description": (
            "One node of the map and both directions of its edges — a repository, a "
            "host, a deployment tool such as kamal or terraform, a backing service "
            "such as postgres, or a third-party vendor such as stripe. Most edges are "
            "extracted and carry the file:line they "
            "were found on. An edge marked ~ is inferred: nothing declared it, it was "
            "resolved by matching one repo's reading against another's, and there is "
            "no line to open. Say which kind you are relying on."
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
        "name": "orgami_live",
        "description": (
            "What the providers said was deployed the last time somebody asked them: "
            "Vercel projects, Fly apps, tagged AWS services, with their state, their "
            "domains and the age of the reading. Unlike the rest of the map this "
            "expires — always quote how old it is, and treat anything over a week as "
            "a rumour. Reads the stored file; it never calls a cloud account."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"repo": {"type": "string"}},
        },
    },
    {
        "name": "orgami_dns",
        "description": (
            "The third parties the organization has an *account* with, read out of its "
            "own public DNS the last time somebody ran `orgami dns`: verification "
            "tokens, mail providers, everything permitted to send as the org, the "
            "DMARC reporting destination, conventional subdomains and the "
            "nameservers. This is the half `orgami scan` can never see — no "
            "repository mentions Google Workspace. Each finding carries the record "
            "and the day it was read, so it can be checked with the same dig. A "
            "record proves an account, never a price. Reads the stored file; it "
            "sends no query."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"vendor": {"type": "string"}},
        },
    },
    {
        "name": "orgami_symbol",
        "description": (
            "Which repository defines a name, and at which file and line — parsed "
            "with tree-sitter, not grepped. Ask this before assuming where a "
            "function, class or type lives, and when the same name turns up in more "
            "than one repository. Only exported definitions are indexed, so no "
            "result means nothing exports that name, not that it does not exist. "
            "Empty until somebody has run `orgami depth`."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
        },
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


def dns(vendor=None):
    d = company_dir()
    if not d:
        return "No orgami company configured. Run `orgami init` or `orgami join`."
    path = os.path.join(d, "map", "dns.json")
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return (
            "Nobody has read the DNS yet — no map/dns.json. The map only knows the "
            "vendors the code names, which leaves out everything the organization "
            "merely has an account with. `orgami dns` reads it, and is the user's "
            "call to run."
        )

    age = None
    if data.get("generated_epoch"):
        age = max(0, int(time.time() - data["generated_epoch"]) // 86400)
    when = "at an unknown time" if age is None else (
        "today" if age == 0 else "yesterday" if age == 1 else f"{age} days ago"
    )

    rows = data.get("vendors") or []
    if vendor:
        want = vendor.lower()
        rows = [
            v for v in rows
            if want in (v.get("id") or "").lower() or want in (v.get("name") or "").lower()
        ]

    out = [
        "Read from the public DNS of "
        + ", ".join(data.get("domains") or ["nothing"])
        + f" {when}. Every line is a record anyone can look up again."
    ]
    if age is not None and age >= 90:
        out.append("The reading is over three months old — say so with any claim from it.")
    out.append("")

    if not rows:
        out.append(
            f"Nothing in the reading matches {vendor}." if vendor
            else "No record matched the vendor catalogue."
        )
    for v in rows:
        out.append(
            f"- {v.get('name')} ({v.get('category')}) on "
            + ", ".join(v.get("domains") or [])
        )
        for e in v.get("evidence") or []:
            out.append(f"    {e.get('at')}")
        if v.get("evidence_omitted"):
            out.append(f"    (+{v['evidence_omitted']} more of the same kind)")

    counts = data.get("counts") or {}
    if counts.get("records_unmatched"):
        out.append("")
        out.append(
            f"{counts['records_unmatched']} of {counts.get('records')} records matched "
            "nothing in the catalogue and were not recorded."
        )
    return "\n".join(out)


def live(repo=None):
    d = company_dir()
    if not d:
        return "No orgami company configured. Run `orgami init` or `orgami join`."
    path = os.path.join(d, "map", "live.json")
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return (
            "Nobody has asked the providers yet — no map/live.json. The map only "
            "says what each repo is configured to deploy to. `orgami live` reads "
            "the providers, and is the user's call to run."
        )

    age = None
    if data.get("generated_epoch"):
        age = max(0, int(time.time() - data["generated_epoch"]) // 86400)
    when = "at an unknown time" if age is None else (
        "today" if age == 0 else "yesterday" if age == 1 else f"{age} days ago"
    )

    rows = data.get("deployments") or []
    if repo:
        rows = [r for r in rows if r.get("repo") == repo]

    out = [f"Read from {', '.join(data.get('providers') or ['nothing'])} {when}."]
    if age is not None and age >= 7:
        out.append("This is older than a week. Treat every line below as a rumour.")
    out.append("")

    if not rows:
        out.append(
            f"Nothing recorded for {repo}." if repo
            else "No deployment could be tied to a repository."
        )
    for r in rows:
        bits = [f"- {r.get('repo')}: {r.get('provider')} {r.get('name')}"]
        if r.get("state"):
            bits.append(f"[{r['state']}]")
        if r.get("urls"):
            bits.append(" ".join(r["urls"]))
        if r.get("match"):
            bits.append(f"(matched by {r['match']})")
        out.append(" ".join(bits))

    unmatched = data.get("unmatched") or []
    if unmatched and not repo:
        out.append("")
        out.append("Running, but nothing ties it to a repository in the map:")
        for u in unmatched:
            out.append(f"- {u.get('provider')} {u.get('name')}")

    for err in data.get("errors") or []:
        out.append("")
        out.append(f"{err.get('provider')} could not be read: {err.get('message')}")
    return "\n".join(out)


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
        if args.get("topic"):
            argv += ["--topic", args["topic"]]
        argv += ["--", text]
        return run(argv)
    if name == "orgami_playbook":
        repo = (args.get("repo") or "").strip()
        if not repo:
            return run(["playbooks"])
        argv = ["playbook", repo]
        if args.get("topic"):
            argv += ["--topic", args["topic"]]
        return run(argv)
    if name == "orgami_decisions":
        return read_file("map", "DECISIONS.md")
    if name == "orgami_live":
        return live(args.get("repo"))
    if name == "orgami_dns":
        return dns(args.get("vendor"))
    if name == "orgami_symbol":
        want = (args.get("name") or "").strip()
        if not want:
            return "Refused: name is required."
        return run(["depth", "--symbol", want])
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
