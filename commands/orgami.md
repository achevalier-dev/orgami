---
description: Load the full orgami page for this repo or the organization
---

Run `orgami context $ARGUMENTS` and use what it prints as the basis for the rest
of this conversation.

Inside a checkout it prints that repo's page: framework, the exact commands to
run and test it, what it talks to and what talks to it, endpoints, environment,
deployment, which repos it usually changes with, recent merged pull requests and
team notes. Anywhere else it prints the organization overview.

Then answer whatever the user asked, citing the evidence line for any claim
taken from the map. If the map's date is more than a week old, say so rather
than presenting it as current.
