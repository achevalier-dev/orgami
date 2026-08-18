# What is actually running

The map is built from committed files: every edge carries the `file:line` it
came from, and two people scanning the same organization get the same map. That
is the whole reason to trust it — and it is also its limit. `fly.toml` says the
repo is *configured* to deploy to Fly. It does not say the app still exists, what
domain it answers on, or that anyone has deployed it since March.

`orgami live` asks the providers.

```bash
orgami live                                # every provider the map already names
orgami live --provider vercel,fly,aws      # only these
orgami live --json                         # the file, on stdout
```

It writes `map/live.json` and nothing else. The graph is not touched.

## Why it is kept apart

A reading from a cloud account is not the same kind of fact as a line in a
committed file:

- **It expires.** `READY` was true when the call was made. Everything rendered
  from `live.json` carries the age of the reading, and after seven days it stops
  being injected into agent context and is labelled a rumour on the repo page.
- **It is not reproducible.** A teammate without the AWS role, or without a
  Vercel token, gets a different answer from the same repository. The map has to
  be the same for everyone; this cannot be.
- **It cannot be checked.** There is no `file:line` to open. Each row records
  which provider and which account it came from, and that is the most it can
  offer.

So `orgami live` is a separate command, on a separate file, and `orgami publish`
leaves it on your machine unless you set `"live_publish": true` in the config.
`orgami weekly` refreshes a reading that already exists, and never starts one.

## Nothing but names and endpoints

Project names, app names, function and service names, hostnames and aliases,
deployment state, the account the reading came from. **No environment variable
values, no secrets, no parameter contents** — `live.json` is a file that ends up
in a git repository the day someone turns publishing on.

## How a deployment is tied to a repository

Never by resemblance. `api-staging` is not attributed to `api`. Three things can
make the link, and each row records which one did:

| `match` | What it means |
|---|---|
| `map` | the graph already has a `deploys-to` edge from exactly one repo to that host — the strongest link, because a committed file put it there |
| `link` | the provider itself says which GitHub repository it builds from, and the organization matches |
| `tag` | an AWS resource carries a tag naming the repository |

Case is not part of the test — GitHub treats `WinIt-backend` and `winit-backend`
as the same name — but nothing less than the whole name is: `winit-backend-dev`
is not `WinIt-backend`, and `scraphome-api` is not `scraphome`.

Anything else lands in `unmatched`, with its state and hostname, and is counted
in the summary line. An unattributed service is a fact worth seeing — it is
usually either a preview environment nobody cleaned up or a service nobody
remembers owning. When nothing at all can be attributed, `orgami context` for
the org says how many things are running unaccounted for.

## The providers

### Fly

Needs `flyctl` on PATH and an existing login. One call, `flyctl apps list
--json`. An app is tied to a repo when the map already has a `deploys-to` edge
to `<app>.fly.dev` — which the scan writes from `fly.toml` — or when the app
name is exactly a repo name.

### Vercel

Needs `VERCEL_TOKEN` ([vercel.com/account/tokens](https://vercel.com/account/tokens)),
and `VERCEL_TEAM_ID` when the projects belong to a team rather than a personal
account. The CLI prints tables rather than JSON, and the field that matters —
which GitHub repository a project builds from — is only in the REST API, so this
reader talks to `api.vercel.com` directly. It reads project names, production
aliases, and the state and time of the production deployment.

### AWS

Needs the `aws` CLI already authenticated, and a region: `aws_region` in the
config, `AWS_REGION`, or the one in your AWS profile.

It reads Lambda functions, ECS services and Elastic Beanstalk environments, and
it enumerates them from the services themselves rather than from the tagging
API. That matters: `resourcegroupstaggingapi get-resources` only returns
resources carrying at least one tag, and on a real account most of what is
running carries none. One organization tested here had 3 of its 16 Lambdas and
0 of its 11 ECS services visible that way — a reader built on tags alone would
have reported an almost empty account as if that were the answer.

Tags are still read, once, and used for attribution where they exist. Beanstalk
is the one AWS service that hands back a hostname, so its environments can also
match a `deploys-to` edge the scan already found.

Nothing in an AWS account records which repository built a resource. Expect the
first run to attribute little or nothing and to list a great deal — that list is
the finding. Tagging what you deploy with `Repository=<repo>` is what turns it
into attribution, and it is worth doing once:

```
Repository = winit-backend
```

## Where it shows up

Once a reading exists:

- **`orgami context <repo>`** gains a `## Running now` section, under what the
  committed files say, with the age of the reading.
- **The session-start injection** gains one line, and only while the reading is
  less than seven days old.
- **`orgami context`** for the whole org lists every repo tied to something
  running.
- **`orgami live`** on its own prints the table and the summary.

## Config

```json
{
  "live": { "providers": ["vercel", "fly"] },
  "aws_region": "eu-west-1",
  "live_publish": false
}
```

`live.providers` is only consulted when the map names no provider of its own —
normally the scan has already found them.
