#!/usr/bin/env python3
"""orgami depth — the symbol layer, parsed rather than pattern-matched.

`orgami scan` reads what a repository *declares about itself*: its manifests,
its deploy configuration, the URLs it writes down. That is the right altitude
for an organization map and it is cheap enough to run over forty repositories.
It is also blind to the inside of the code — it cannot tell you which repo
defines `chargeCustomer`, and it can only find an import by grepping for a name,
which matches a comment and a changelog just as happily as an import statement.

This pass parses. Every file goes through a tree-sitter grammar, so a definition
is a definition node and an import is an import node, and the line number is the
one the parser reports rather than the one grep happened to land on. That is
strictly better evidence than the scan can produce, which is why the edges it
contributes are `extracted`.

It is a separate command for the reason `orgami live` is: it needs something
orgami otherwise does not. The rest of orgami is bash, gh, jq. This needs Python
and a set of compiled grammars, so it installs into its own virtualenv, is never
required, and the map is complete without it.

Reads the checkouts `orgami scan` already made. Writes map/depth.json.
"""

import argparse
import json
import os
import sys
import time
from concurrent.futures import ProcessPoolExecutor

# --- what the parser is pointed at -------------------------------------------
# Directories that hold somebody else's code, build output, or fixtures. Parsing
# node_modules would triple the runtime to describe libraries the team did not
# write, and a symbol defined in a test fixture is not part of the repo's
# surface. Same list the rest of orgami skips, kept in step with lib/profile.sh.

SKIP_DIRS = {
    ".git", "node_modules", "vendor", "dist", "build", ".next", "out",
    "coverage", "__pycache__", ".venv", "venv", "target", "Pods", ".terraform",
    "bower_components", ".yarn", ".pnpm-store", "third_party", "generated",
    "migrations", ".cache", ".idea", ".gradle", "DerivedData",
}

TEST_DIRS = {
    "test", "tests", "spec", "__tests__", "e2e", "testdata", "fixtures",
    "mocks", "__mocks__", "cypress",
}

# A generated or minified file parses fine and tells you nothing. So does a
# 5 MB vendored bundle, slowly.
MAX_BYTES = 512 * 1024
SKIP_SUFFIXES = (
    ".min.js", ".min.css", ".bundle.js", ".map", ".lock", ".sum",
    ".pb.go", "_pb2.py", ".g.dart", ".generated.ts", ".d.ts",
)

# Per repo, so one monorepo cannot produce a depth.json nobody can open. The
# counts stay exact; only the listing is cut, and the cut is reported.
#
# What gets kept is the repo's *surface*: exported definitions, and imports that
# name another package rather than a file next door. A private helper and a
# `require("../utils")` are real, and they are counted, but neither is something
# another repository could ever depend on, and forty repos' worth of them is
# several megabytes of file nobody opens.
MAX_SYMBOLS_KEPT = 1500
MAX_IMPORTS_KEPT = 400


# --- the languages ------------------------------------------------------------
# Node types rather than tree-sitter queries. A query has to be written and
# validated per grammar and breaks quietly when a grammar renames a node between
# releases; a node-type table degrades to "found less" instead of "raised".
#
# defs:    node type -> what to call it
# imports: node types whose text names another module
# name:    where the identifier lives, when it is not the `name` field

LANGS = {
    "python": {
        "exts": [".py"],
        "defs": {"function_definition": "function", "class_definition": "class"},
        "imports": {"import_statement", "import_from_statement"},
    },
    "javascript": {
        "exts": [".js", ".jsx", ".mjs", ".cjs"],
        "defs": {
            "function_declaration": "function",
            "generator_function_declaration": "function",
            "class_declaration": "class",
            "method_definition": "method",
            "variable_declarator": "function",  # const x = () => …
        },
        "imports": {"import_statement", "export_statement"},
    },
    "typescript": {
        "exts": [".ts"],
        "defs": {
            "function_declaration": "function",
            "class_declaration": "class",
            "method_definition": "method",
            "interface_declaration": "interface",
            "type_alias_declaration": "type",
            "enum_declaration": "enum",
            "variable_declarator": "function",
        },
        "imports": {"import_statement", "export_statement"},
    },
    "tsx": {
        "exts": [".tsx"],
        "defs": {
            "function_declaration": "function",
            "class_declaration": "class",
            "method_definition": "method",
            "interface_declaration": "interface",
            "type_alias_declaration": "type",
            "variable_declarator": "function",
        },
        "imports": {"import_statement", "export_statement"},
    },
    "go": {
        "exts": [".go"],
        "defs": {
            "function_declaration": "function",
            "method_declaration": "method",
            "type_declaration": "type",
        },
        "imports": {"import_spec"},
    },
    "ruby": {
        "exts": [".rb"],
        "defs": {"method": "method", "class": "class", "module": "module"},
        "imports": set(),  # require is a method call, handled below
    },
    "rust": {
        "exts": [".rs"],
        "defs": {
            "function_item": "function",
            "struct_item": "struct",
            "enum_item": "enum",
            "trait_item": "trait",
        },
        "imports": {"use_declaration"},
    },
    "java": {
        "exts": [".java"],
        "defs": {
            "method_declaration": "method",
            "class_declaration": "class",
            "interface_declaration": "interface",
        },
        "imports": {"import_declaration"},
    },
    "php": {
        "exts": [".php"],
        "defs": {
            "function_definition": "function",
            "method_declaration": "method",
            "class_declaration": "class",
            "interface_declaration": "interface",
        },
        "imports": {"namespace_use_declaration"},
    },
    "csharp": {
        "exts": [".cs"],
        "defs": {
            "method_declaration": "method",
            "class_declaration": "class",
            "interface_declaration": "interface",
            "record_declaration": "record",
        },
        "imports": {"using_directive"},
    },
    "kotlin": {
        "exts": [".kt", ".kts"],
        "defs": {"function_declaration": "function", "class_declaration": "class"},
        "imports": {"import_header"},
    },
    "swift": {
        "exts": [".swift"],
        "defs": {
            "function_declaration": "function",
            "class_declaration": "class",
            "protocol_declaration": "protocol",
        },
        "imports": {"import_declaration"},
    },
    "bash": {
        "exts": [".sh", ".bash"],
        "defs": {"function_definition": "function"},
        "imports": set(),
    },
    "c": {
        "exts": [".c", ".h"],
        "defs": {"function_definition": "function", "struct_specifier": "struct"},
        "imports": {"preproc_include"},
    },
    "cpp": {
        "exts": [".cc", ".cpp", ".cxx", ".hpp"],
        "defs": {
            "function_definition": "function",
            "class_specifier": "class",
            "struct_specifier": "struct",
        },
        "imports": {"preproc_include"},
    },
}

EXT_TO_LANG = {e: name for name, spec in LANGS.items() for e in spec["exts"]}

# Extensions orgami can see but has no grammar for. Reported as a count, so
# "we do not parse your Elixir" is visible rather than silently absent.
UNSUPPORTED_EXTS = {
    ".ex", ".exs", ".scala", ".clj", ".hs", ".ml", ".erl", ".dart", ".lua",
    ".pl", ".r", ".jl", ".zig", ".nim", ".groovy", ".vb", ".f90",
}


def load_parsers(languages):
    """One parser per language, or a clear failure. Nothing here degrades to a
    guess: without a grammar the pass reports the language as unparsed."""
    try:
        from tree_sitter_language_pack import get_parser
    except ImportError:
        sys.stderr.write(
            "orgami: tree-sitter is not installed in this interpreter.\n"
            "        run: orgami depth --setup\n"
        )
        raise SystemExit(3)

    parsers, missing = {}, []
    for lang in languages:
        try:
            parsers[lang] = get_parser(lang)
        except Exception:
            missing.append(lang)
    return parsers, missing


# --- reading one file ---------------------------------------------------------


def node_text(src, node):
    return src[node.start_byte:node.end_byte].decode("utf-8", "replace")


def def_name(src, node, lang):
    """The identifier a definition binds. `name` field where the grammar has
    one, first identifier-ish child otherwise — C and C++ bury it in a
    declarator, Ruby and Swift name it directly."""
    n = node.child_by_field_name("name")
    if n is not None:
        return node_text(src, n).strip()

    n = node.child_by_field_name("declarator")
    while n is not None:
        inner = n.child_by_field_name("declarator")
        if inner is None:
            break
        n = inner
    if n is not None and n.type in ("identifier", "field_identifier"):
        return node_text(src, n).strip()

    for child in node.children:
        if child.type in ("identifier", "type_identifier", "constant",
                          "field_identifier", "simple_identifier", "name"):
            return node_text(src, child).strip()
    return ""


def is_exported(src, node, lang, name):
    """Whether this definition is part of the repo's surface, by whatever each
    language uses to say so. Where a language has no such marker, everything at
    the top level counts — which is what its readers assume too."""
    if not name:
        return False
    if lang == "go":
        return name[0].isupper()
    if lang == "python":
        return not name.startswith("_")
    if lang in ("javascript", "typescript", "tsx"):
        p = node
        for _ in range(4):
            p = p.parent
            if p is None:
                return False
            if p.type == "export_statement":
                return True
        return False
    if lang == "rust":
        return any(c.type == "visibility_modifier" for c in node.children)
    if lang in ("java", "csharp", "kotlin", "swift", "php"):
        head = node_text(src, node)[:120]
        return "public" in head or (lang in ("kotlin", "swift") and "private" not in head)
    if lang == "ruby":
        return not name.startswith("_")
    return True


def import_module(src, node, lang):
    """The module a node names, normalised to the thing you could look up.
    Quotes, angle brackets, `from`/`use`/`import` keywords and trailing
    semicolons all removed; anything that does not reduce to a module path is
    dropped rather than guessed at."""
    if lang in ("javascript", "typescript", "tsx"):
        s = node.child_by_field_name("source")
        if s is None:
            return ""
        return node_text(src, s).strip("\"'`")
    if lang == "python":
        m = node.child_by_field_name("module_name")
        if m is not None:
            return node_text(src, m).strip()
        for child in node.children:
            if child.type in ("dotted_name", "relative_import"):
                return node_text(src, child).strip()
        return ""
    if lang == "go":
        p = node.child_by_field_name("path")
        if p is not None:
            return node_text(src, p).strip('"')
        return node_text(src, node).strip('"').strip()

    text = node_text(src, node).strip()
    for kw in ("import ", "using ", "use ", "#include", "require ", "namespace "):
        if text.startswith(kw):
            text = text[len(kw):]
    return text.strip().strip(";").strip("\"'<>").strip()


JS_LANGS = ("javascript", "typescript", "tsx")


def commonjs_exports(src, node, out):
    """`module.exports = {a, b}`, `module.exports.c = …`, `exports.d = …`.

    Half the JavaScript in a working organization predates ES modules, and to a
    grammar an assignment is an assignment — nothing marks these as the public
    surface the way an `export` keyword does. So the names on the left of a
    `module.exports` assignment, and the identifiers in the object on its right,
    are collected per file and the definitions matching them are marked
    exported afterwards."""
    left = node.child_by_field_name("left")
    if left is None:
        return
    lt = node_text(src, left).strip()
    if not (lt.startswith("module.exports") or lt.startswith("exports.")):
        return
    if "." in lt.split("exports", 1)[-1]:
        out.add(lt.rsplit(".", 1)[-1])
    right = node.child_by_field_name("right")
    if right is None:
        return
    stack = [right]
    seen = 0
    while stack and seen < 400:
        n = stack.pop()
        seen += 1
        if n.type in ("identifier", "property_identifier", "shorthand_property_identifier"):
            out.add(node_text(src, n).strip())
        stack.extend(n.children)


def walk(src, root, spec, lang, rel, symbols, imports, exported_names):
    """One iterative pass over the tree. Recursion blows the stack on generated
    files, and those are exactly the ones nobody wants a crash from."""
    defs, imps = spec["defs"], spec["imports"]
    stack = [root]
    while stack:
        node = stack.pop()
        t = node.type

        if lang in JS_LANGS and t == "assignment_expression":
            commonjs_exports(src, node, exported_names)
        elif lang in JS_LANGS and t == "call_expression":
            # require('x') — the other half of how JavaScript names a module.
            fn = node.child_by_field_name("function")
            if fn is not None and node_text(src, fn).strip() == "require":
                a = node.child_by_field_name("arguments")
                if a is not None:
                    mod = node_text(src, a).strip("()").strip().strip("\"'`")
                    if mod and len(mod) < 200 and "\n" not in mod:
                        imports.append({"module": mod, "file": rel,
                                        "line": node.start_point[0] + 1})

        if t in imps:
            mod = import_module(src, node, lang)
            if mod and len(mod) < 200:
                imports.append({"module": mod, "file": rel,
                                "line": node.start_point[0] + 1})
        elif lang == "ruby" and t == "call":
            m = node.child_by_field_name("method")
            if m is not None and node_text(src, m) in ("require", "require_relative"):
                a = node.child_by_field_name("arguments")
                if a is not None:
                    mod = node_text(src, a).strip("()").strip("\"'")
                    if mod and len(mod) < 200:
                        imports.append({"module": mod, "file": rel,
                                        "line": node.start_point[0] + 1})

        if t in defs:
            # `const x = () => {}` is a function; `const x = 3` is not, and the
            # grammar gives both the same node.
            if t == "variable_declarator":
                v = node.child_by_field_name("value")
                if v is None or v.type not in ("arrow_function", "function",
                                               "function_expression"):
                    stack.extend(node.children)
                    continue
            name = def_name(src, node, lang)
            if name and len(name) < 120:
                symbols.append({
                    "name": name,
                    "kind": defs[t],
                    "file": rel,
                    "line": node.start_point[0] + 1,
                    "exported": is_exported(src, node, lang, name),
                })

        stack.extend(node.children)


# --- one repository -----------------------------------------------------------


def repo_files(root):
    """Every source file worth parsing, with the language it is written in.
    Test directories are walked for imports but their symbols are dropped: a
    helper defined in a fixture is not part of the repo's surface."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in SKIP_DIRS and not d.startswith(".")]
        rel_dir = os.path.relpath(dirpath, root)
        in_test = any(part in TEST_DIRS for part in rel_dir.split(os.sep))
        for fn in filenames:
            ext = os.path.splitext(fn)[1].lower()
            if fn.endswith(SKIP_SUFFIXES):
                continue
            lang = EXT_TO_LANG.get(ext)
            if lang is None:
                if ext in UNSUPPORTED_EXTS:
                    yield None, ext, None, False
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, root)
            yield lang, ext, (path, rel), in_test


def scan_repo(job):
    name, root = job
    langs_here = set()
    files = []
    unsupported = {}
    for lang, ext, entry, in_test in repo_files(root):
        if entry is None:
            unsupported[ext] = unsupported.get(ext, 0) + 1
            continue
        langs_here.add(lang)
        files.append((lang, entry[0], entry[1], in_test))

    if not files:
        return {"name": name, "files": 0, "parsed": 0, "skipped": 0,
                "languages": {}, "symbols": [], "symbol_count": 0,
                "exported_count": 0, "symbols_truncated": False,
                "imports": [], "import_count": 0, "external_modules": 0,
                "internal_imports": 0, "imports_truncated": False,
                "unsupported": unsupported, "errors": 0, "missing_grammars": []}

    parsers, missing = load_parsers(sorted(langs_here))
    symbols, imports = [], []
    counts, parsed, skipped, errors = {}, 0, 0, 0

    for lang, path, rel, in_test in files:
        parser = parsers.get(lang)
        if parser is None:
            skipped += 1
            continue
        try:
            if os.path.getsize(path) > MAX_BYTES:
                skipped += 1
                continue
            with open(path, "rb") as fh:
                src = fh.read()
        except OSError:
            skipped += 1
            continue

        try:
            tree = parser.parse(src)
        except Exception:
            errors += 1
            continue

        before = len(symbols)
        exported_names = set()
        walk(src, tree.root_node, LANGS[lang], lang, rel, symbols, imports,
             exported_names)
        if exported_names:
            for sym in symbols[before:]:
                if sym["name"] in exported_names:
                    sym["exported"] = True
        if in_test:
            del symbols[before:]
        parsed += 1
        counts[lang] = counts.get(lang, 0) + 1

    symbol_count = len(symbols)
    exported = [s for s in symbols if s["exported"]]
    kept = exported[:MAX_SYMBOLS_KEPT]

    # One row per module, with the first place it is imported and how often.
    # Relative paths are counted and dropped: `../db` says something about this
    # repo's own layout and nothing about the organization.
    external, internal = {}, 0
    for imp in imports:
        mod = imp["module"]
        if mod.startswith(".") or mod.startswith("/"):
            internal += 1
            continue
        row = external.get(mod)
        if row is None:
            external[mod] = {"module": mod, "file": imp["file"],
                             "line": imp["line"], "n": 1}
        else:
            row["n"] += 1
    ext_rows = sorted(external.values(), key=lambda r: (-r["n"], r["module"]))

    return {
        "name": name,
        "files": len(files),
        "parsed": parsed,
        "skipped": skipped,
        "errors": errors,
        "languages": dict(sorted(counts.items(), key=lambda kv: -kv[1])),
        "symbols": sorted(kept, key=lambda s: (s["file"], s["line"])),
        "symbol_count": symbol_count,
        "exported_count": len(exported),
        "symbols_truncated": len(exported) > len(kept),
        "imports": ext_rows[:MAX_IMPORTS_KEPT],
        "import_count": len(imports),
        "external_modules": len(external),
        "internal_imports": internal,
        "imports_truncated": len(ext_rows) > MAX_IMPORTS_KEPT,
        "unsupported": unsupported,
        "missing_grammars": missing,
    }


def main():
    ap = argparse.ArgumentParser(prog="orgami depth")
    ap.add_argument("--src", required=True, help="directory of checkouts")
    ap.add_argument("--out", required=True, help="where to write depth.json")
    ap.add_argument("--only", default="", help="one repository")
    ap.add_argument("--jobs", type=int, default=4)
    args = ap.parse_args()

    if not os.path.isdir(args.src):
        sys.stderr.write("orgami: no checkouts — run: orgami scan\n")
        return 2

    repos = sorted(
        (d.name, d.path) for d in os.scandir(args.src)
        if d.is_dir() and not d.name.startswith(".")
    )
    if args.only:
        repos = [r for r in repos if r[0] == args.only]
    if not repos:
        sys.stderr.write("orgami: nothing to parse in %s\n" % args.src)
        return 2

    # Fail on the first repo rather than after twenty minutes if the grammars
    # are not there at all.
    load_parsers(["python"])

    started = time.time()
    results = []
    done = 0
    with ProcessPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for res in pool.map(scan_repo, repos):
            results.append(res)
            done += 1
            if sys.stderr.isatty():
                sys.stderr.write("\r\033[2K  parsed %d/%d repos — %s"
                                 % (done, len(repos), res["name"][:32]))
                sys.stderr.flush()
    if sys.stderr.isatty():
        sys.stderr.write("\n")

    unsupported = {}
    for r in results:
        for ext, n in r.pop("unsupported", {}).items():
            unsupported[ext] = unsupported.get(ext, 0) + n

    import tree_sitter

    out = {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "generated_epoch": int(time.time()),
        "parser": "tree-sitter %s" % getattr(tree_sitter, "__version__", "?"),
        "seconds": round(time.time() - started, 1),
        "repos": sorted(results, key=lambda r: r["name"]),
        "totals": {
            "repos": len(results),
            "files_parsed": sum(r["parsed"] for r in results),
            "symbols": sum(r["symbol_count"] for r in results),
            "exported": sum(r["exported_count"] for r in results),
            "imports": sum(r["import_count"] for r in results),
            "external_modules": sum(r["external_modules"] for r in results),
        },
        "unparsed_extensions": dict(sorted(unsupported.items(), key=lambda kv: -kv[1])),
    }

    parent = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(parent, exist_ok=True)
    with open(args.out, "w") as fh:
        json.dump(out, fh, indent=1)
        fh.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
