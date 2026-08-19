# shellcheck shell=bash
# Which third parties a repository actually uses, from committed files only.
#
# The graph already knows what a repo deploys to and what it depends on. What it
# could not say is who the organization is *paying*: a dependency on `stripe` and
# a `SENTRY_DSN` in `.env.example` are the two most reliable statements a
# codebase makes about its suppliers, and neither of them shows up as a host or a
# tool. `lib/vendors.tsv` is the catalogue; this file is the matcher.
#
# Nothing here reaches the network, reads a credential or looks at a value. It
# collects *facts* — a package name, an environment variable's name, a hostname
# in a literal URL, a terraform provider, a workflow's `uses:` line — each with
# the file and line it came from, and matches those against the catalogue. A
# vendor edge is therefore always extracted, never inferred, and always points
# at something a person can open.
#
# The facts are gathered here rather than taken from `lib/profile.sh` for one
# reason: `profile_env` and `profile_calls` deliberately throw the line number
# away and cap their lists, because a repo card wants a short list of names, not
# citations. An edge without a line is not an edge in this tool, so the same
# files get read again with `grep -n`. Everything else is reused — the exclusion
# lists that keep `node_modules` and test fixtures out are `profile.sh`'s own.

VENDOR_CATALOG=${VENDOR_CATALOG:-${ROOT:-.}/lib/vendors.tsv}

# Every signal kind the catalogue is allowed to use, as one alternation. A `|`
# in the signals column only opens a new signal when one of these words and a
# colon follow it, which is what lets a regex carry alternation of its own.
#
# This list is the single place a kind is declared, and it is load-bearing in a
# way that is easy to miss: a kind that is *not* here raises no error. It is
# swallowed into the previous signal's regex, and every vendor behind it stops
# matching silently — the map simply gets smaller. `test/dns_match_test.sh`
# asserts a `mx:` signal survives parsing for exactly that reason.
#
# pkg, env, host, tf and action are facts about committed files, gathered here.
# mx, spf, txt, cname, ns and dmarc are facts about public DNS, gathered by
# lib/dns.sh. The two sets never meet: a fact carries its kind, and a signal
# only matches a fact of the same kind, so a `host:` signal can never be
# satisfied by a CNAME and vice versa.
VENDOR_SIGNAL_KINDS='pkg|env|host|tf|action|mx|spf|txt|cname|ns|dmarc'

# Turns `grep -rno` output — path:line:match — into `<kind>\t<value>\t<rel>:<line>`.
# The split is on the first `:<digits>:` rather than on colons, because the match
# is regularly a URL and carries a colon of its own. $3 and $4 are regexes
# trimmed off the head and tail of the token.
vendors_from_grep() {
  awk -v kind="$1" -v src="$2/" -v head="${3-}" -v tail="${4-}" '
    {
      if (!match($0, ":[0-9]+:")) next
      path = substr($0, 1, RSTART - 1)
      ln = substr($0, RSTART + 1, RLENGTH - 2)
      tok = substr($0, RSTART + RLENGTH)
      if (index(path, src) == 1) path = substr(path, length(src) + 1)
      if (head != "") sub(head, "", tok)
      if (tail != "") sub(tail, "", tok)
      if (tok != "") printf "%s\t%s\t%s:%s\n", kind, tok, path, ln
    }'
}

# Dependencies out of a JSON manifest. jq decides which keys are dependencies —
# nothing else may parse JSON — and the second pass only decides which line to
# point at, which is a lookup, not a parse.
vendors_deps_json() {
  local src=$1 rel=$2 names
  local file="$src/$rel"
  [[ -f $file ]] || return 0
  names=$(jq -r '[(.dependencies // {}), (.devDependencies // {}),
                  (.peerDependencies // {}), (.optionalDependencies // {}),
                  (.require // {}), (."require-dev" // {})]
                 | add // {} | keys[]' "$file" 2>/dev/null) || return 0
  [[ -n $names ]] || return 0
  awk -v rel="$rel" '
    NR == FNR { want[$0] = 1; next }
    {
      line = $0
      while (match(line, "\"[^\"]+\"[[:space:]]*:")) {
        key = substr(line, RSTART + 1, RLENGTH - 1)
        sub("\"[[:space:]]*:$", "", key)
        if (key in want) printf "pkg\t%s\t%s:%d\n", key, rel, FNR
        line = substr(line, RSTART + RLENGTH)
      }
    }' <(printf '%s\n' "$names") "$file"
}

# Dependencies out of the manifests that are not JSON. One awk per file, because
# each format says "this is a dependency" differently and none of them says it
# in a way the next one would recognise.
vendors_deps_text() {
  local src=$1 rel
  for rel in requirements.txt requirements-dev.txt pyproject.toml Gemfile go.mod Cargo.toml; do
    [[ -f $src/$rel ]] || continue
    awk -v rel="$rel" '
      function emit(name) { if (name != "") printf "pkg\t%s\t%s:%d\n", name, rel, FNR }
      index(rel, "requirements") == 1 {
        if (match($0, "^[[:space:]]*[A-Za-z][A-Za-z0-9._-]*")) {
          t = substr($0, RSTART, RLENGTH); sub("^[[:space:]]*", "", t); emit(t)
        }
        next
      }
      rel == "Gemfile" {
        if (match($0, "^[[:space:]]*gem[[:space:]]+[\"'"'"'][A-Za-z][A-Za-z0-9._-]*")) {
          t = substr($0, RSTART, RLENGTH); sub(".*[\"'"'"']", "", t); emit(t)
        }
        next
      }
      # A go module path is the only thing in go.mod shaped like a domain
      # followed by a path, which keeps the version and the directives out.
      rel == "go.mod" {
        if (match($0, "[a-z0-9][a-z0-9.-]*\\.[a-z][a-z]*/[A-Za-z0-9._/-]+"))
          emit(substr($0, RSTART, RLENGTH))
        next
      }
      # TOML: a dependency is either a table key — poetry and cargo write
      # `stripe = "^5"` — or a quoted requirement inside an array, which is how
      # PEP 621 writes `"stripe>=5"`. Metadata keys land here too; `name` and
      # `version` are in no catalogue, so they cost nothing.
      {
        if (match($0, "^[[:space:]]*[A-Za-z][A-Za-z0-9._-]*[[:space:]]*=")) {
          t = substr($0, RSTART, RLENGTH)
          sub("^[[:space:]]*", "", t); sub("[[:space:]]*=$", "", t); emit(t)
        }
        # Every quoted requirement on the line, not just the first: a short
        # dependency array is routinely written on one.
        line = $0
        while (match(line, "\"[A-Za-z][A-Za-z0-9._-]*[\"<>=~!;,[]")) {
          t = substr(line, RSTART + 1, RLENGTH - 2); emit(t)
          line = substr(line, RSTART + RLENGTH)
        }
      }' "$src/$rel"
  done
}

# Environment variable *names*. Never a value: this runs over other people's
# repositories, and a `.env` that should not have been committed is exactly the
# file this would otherwise read out loud.
vendors_env_names() {
  local src=$1 f
  for f in .env.example .env.sample .env.template .env.dist config/.env.example; do
    [[ -f $src/$f ]] || continue
    awk -v rel="$f" '
      match($0, "^[[:space:]]*(export[[:space:]]+)?[A-Z][A-Z0-9_]*=") {
        t = substr($0, RSTART, RLENGTH)
        sub("^[[:space:]]*", "", t); sub("^export[[:space:]]+", "", t); sub("=$", "", t)
        printf "env\t%s\t%s:%d\n", t, rel, FNR
      }' "$src/$f"
  done
  grep -rnoE 'process\.env\.[A-Z][A-Z0-9_]{2,}' "$src" "${PROFILE_EXCL[@]}" 2>/dev/null |
    vendors_from_grep env "$src" '^process\.env\.' || true
  grep -rnoE "os\.environ(\.get)?[\[(]['\"][A-Z][A-Z0-9_]{2,}" "$src" --include='*.py' \
    "${PROFILE_EXCL[@]}" 2>/dev/null |
    vendors_from_grep env "$src" "^.*['\"]" || true
  grep -rnoE "ENV\[['\"][A-Z][A-Z0-9_]{2,}" "$src" --include='*.rb' \
    "${PROFILE_EXCL[@]}" 2>/dev/null |
    vendors_from_grep env "$src" "^.*['\"]" || true
}

# A URL that names a file, a schema or a documentation page is a reference, not
# a supplier: `"$schema": "https://anthropic.com/…​.json"` says nothing about who
# is being paid. This is the one thing NOISE_DOMAINS was doing for the host nodes
# that vendor matching still needs, and it is done on the path rather than the
# domain, so no vendor has to be blacklisted to get it.
VENDOR_URL_NOISE='\.(json|md|ya?ml|svg|png|jpe?g|gif|txt|xml|pdf|html?)([?#][^:]*)?$|/docs?/|/blog/|/schema'

# Hosts, from literal URLs. Test paths are excluded for the same reason
# `profile_calls` excludes them: a URL in a fixture is a stub, not a supplier.
# NOISE_DOMAINS itself is *not* applied — see the header of lib/vendors.tsv.
vendors_hosts() {
  local src=$1
  grep -rnoE "https?://[a-zA-Z0-9._-]+[^[:space:]\"'\`<>]*" "$src" \
    --include='*.js' --include='*.ts' --include='*.jsx' --include='*.tsx' \
    --include='*.py' --include='*.rb' --include='*.go' --include='*.php' \
    --include='*.env*' --include='*.yml' --include='*.yaml' --include='*.json' \
    --include='*.tf' --include='*.toml' \
    "${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" 2>/dev/null |
    grep -vE "$VENDOR_URL_NOISE" |
    vendors_from_grep host "$src" '^https?://' '[:/?#].*$' || true
  # Connection strings carry the vendor in the host too, and are the only place
  # a managed database ever names itself.
  grep -rnoE '(mongodb(\+srv)?|rediss?|postgres(ql)?|amqps?)://[^[:space:]"'"'"']+' "$src" \
    --include='*.env*' --include='*.yml' --include='*.yaml' --include='*.json' \
    --include='*.js' --include='*.ts' --include='*.py' --include='*.rb' --include='*.go' \
    "${PROFILE_EXCL[@]}" "${PROFILE_TEST_EXCL[@]}" 2>/dev/null |
    vendors_from_grep host "$src" '^[a-z+]*://([^@/]*@)?' '[:/?].*$' || true
}

# Terraform providers, both spellings: the `provider "x"` block and the
# `source = "hashicorp/x"` line inside required_providers.
vendors_terraform() {
  local src=$1
  grep -rnoE '^[[:space:]]*provider[[:space:]]+"[a-z0-9_-]+"' "$src" --include='*.tf' \
    "${PROFILE_EXCL[@]}" 2>/dev/null |
    vendors_from_grep tf "$src" '^[^"]*"' '".*$' || true
  grep -rnoE 'source[[:space:]]*=[[:space:]]*"[A-Za-z0-9-]+/[a-z0-9_-]+"' "$src" --include='*.tf' \
    "${PROFILE_EXCL[@]}" 2>/dev/null |
    vendors_from_grep tf "$src" '^[^"]*"[A-Za-z0-9-]*/' '".*$' || true
}

vendors_actions() {
  local src=$1
  [[ -d $src/.github/workflows ]] || return 0
  grep -rnoE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$src/.github/workflows" 2>/dev/null |
    vendors_from_grep action "$src" '^uses:[[:space:]]*' || true
}

# Every fact one checkout offers, deduplicated on kind and value. Sorted first so
# that the evidence a repeated name keeps is the same one on every machine —
# `grep -r` walks the filesystem in whatever order it is handed.
vendors_facts() {
  local src=$1
  {
    vendors_deps_json "$src" package.json
    vendors_deps_json "$src" composer.json
    vendors_deps_text "$src"
    vendors_env_names "$src"
    vendors_hosts "$src"
    vendors_terraform "$src"
    vendors_actions "$src"
  } 2>/dev/null | sort -u | awk -F'\t' '!seen[$1 FS $2]++'
}

# The catalogue against one set of facts, one line per matched vendor:
# <id>\t<name>\t<category>\t<portal>\t<signal-kind>\t<evidence>[\t<flags>].
#
# `flags` goes last, and is left off the line entirely when the vendor has none.
# Both halves of that matter, and neither is cosmetic. Every caller reads these
# lines with `IFS=$'\t' read -r`, and a tab is IFS *whitespace*: a run of them
# collapses into one delimiter, so an empty field in the middle of the line does
# not arrive empty — it disappears, and every field after it shifts one to the
# left. A flags column between the portal and the signal kind would therefore
# have handed the signal kind to `portal` on the ninety-five rows that carry no
# flag. A missing field at the *end* is the one case `read` handles the way
# anyone would expect: the variable is simply empty.
#
# Two modes, because the two callers want different things.
#
# `strongest` — the default, and what a repository scan wants. A vendor found by
# four signals is still one vendor, so only the strongest survives: a manifest
# entry is a commitment, a terraform provider and a workflow action are
# configuration, an environment variable is a promise the deployment makes, and
# a hostname in a string is a mention. In that order.
#
# `all` — what a DNS reading wants. A domain whose MX points at Google and whose
# apex carries a google-site-verification token is saying two different things,
# and a reader checking the finding wants both records rather than whichever one
# this file happened to rank first. One row per vendor, kind and record.
vendors_match() {
  local facts=$1 mode=${2:-strongest}
  [[ -f $VENDOR_CATALOG ]] || die "no vendor catalogue at $VENDOR_CATALOG"
  awk -F'\t' -v cat="$VENDOR_CATALOG" -v mode="$mode" \
    -v kinds="^($VENDOR_SIGNAL_KINDS):" '
    function addsig(sig, id, name, category, portal, flags,   p) {
      p = index(sig, ":")
      if (p == 0) return
      ns++
      skind[ns] = substr(sig, 1, p - 1); sre[ns] = substr(sig, p + 1)
      sid[ns] = id; sname[ns] = name; scat[ns] = category; sportal[ns] = portal
      sflags[ns] = flags
    }
    BEGIN {
      rank["pkg"] = 1; rank["tf"] = 2; rank["action"] = 3
      rank["env"] = 4; rank["host"] = 5
      # The DNS order, on the same scale and never compared against the one
      # above: a verification token is a vendor saying this organization proved
      # it owns the domain, mail routing is where the mailboxes are, and a
      # nameserver is the weakest — it says who serves the zone, not who is
      # billed for what runs on it.
      rank["txt"] = 1; rank["mx"] = 2; rank["dmarc"] = 3
      rank["spf"] = 4; rank["cname"] = 5; rank["ns"] = 6
      while ((getline row < cat) > 0) {
        if (row ~ /^#/ || row ~ /^[[:space:]]*$/) continue
        # split() clears f, so a five-column row leaves f[6] empty rather than
        # inheriting the flags of the last row that carried some. That is the
        # whole reason `flags` is optional at the end of the row and not
        # anywhere else: every earlier column is positional, and a row that
        # stopped short of one would shift portal into signals.
        nf = split(row, f, "\t")
        if (nf < 4) continue
        # A `|` only opens a new signal when a kind and a colon follow it, so a
        # regex may use alternation without being cut in half.
        n = split(f[4], part, "|")
        cur = ""
        for (i = 1; i <= n; i++) {
          if (part[i] ~ kinds) {
            if (cur != "") addsig(cur, f[1], f[2], f[3], f[5], f[6])
            cur = part[i]
          } else if (cur != "") {
            cur = cur "|" part[i]
          }
        }
        if (cur != "") addsig(cur, f[1], f[2], f[3], f[5], f[6])
      }
      close(cat)
    }
    {
      for (i = 1; i <= ns; i++) {
        if (skind[i] != $1 || $2 !~ sre[i]) continue
        key = (mode == "all") ? sid[i] SUBSEP skind[i] SUBSEP $3 : sid[i]
        r = rank[skind[i]]
        if (!(key in best) || r < best[key]) {
          best[key] = r; ev[key] = $3; kd[key] = skind[i]; vid[key] = sid[i]
          nm[key] = sname[i]; ct[key] = scat[i]; pt[key] = sportal[i]
          fl[key] = sflags[i]
        }
      }
    }
    END {
      for (key in best) {
        printf "%s\t%s\t%s\t%s\t%s\t%s",
          vid[key], nm[key], ct[key], pt[key], kd[key], ev[key]
        if (fl[key] != "") printf "\t%s", fl[key]
        printf "\n"
      }
    }' "$facts" | sort
}

# One repo into $EMIT, alongside everything else scan_repo emits. Safe in
# parallel: the only file it writes outside its own temp is $EMIT, which is this
# repo's alone.
vendors_scan() {
  local repo=$1 src=$2 facts id name category portal kind ev flags
  [[ -d $src ]] || return 0
  facts=$(mktemp) || return 0
  vendors_facts "$src" >"$facts"
  while IFS=$'\t' read -r id name category portal kind ev flags; do
    [[ -n $id && -n $ev ]] || continue
    # The catalogue's flags ride into the node's meta so a map can be read
    # without the catalogue beside it. `lib/advise.jq` still falls back to
    # lib/vendors.tsv, because every map scanned before this column existed has
    # vendor nodes without it and nobody should have to rescan to get advice.
    emit_node "vendor:$id" vendor "$name" \
      "$(jq -cn --arg c "$category" --arg p "$portal" --arg f "$flags" \
         '{category: $c, portal: $p,
           flags: ($f | if . == "" then [] else split(",") end)}')"
    # The signal rides along on the edge. `lib/advise.jq` otherwise has to read
    # the kind back off the filename it was matched in, which is a guess where
    # this is a record.
    emit_edge "repo:$repo" "vendor:$id" uses "$ev" extracted "$kind"
  done < <(vendors_match "$facts")
  rm -f "$facts"
}
