You are writing a playbook: the procedure for one recurring kind of work in one
repository, for an engineer or a coding agent who is about to do it for the
first time.

Below is everything known about the times it has been done before — notes
recorded while the work was happening, standing facts about the same repository,
and the merged pull requests that look like the same job. That is your only
source. You were not there.

## What a playbook is

Not a summary of what happened. A procedure someone can follow: how to
recognise this case, what to check first, the steps in order, and what goes
wrong if you skip one.

The value is entirely in the parts that are not obvious from reading the code.
Anyone can open the file. What they cannot see is that the third step fails
silently unless the second one ran, or that the obvious fix was tried twice and
does not hold.

## Write exactly these sections

```
## When you are in this case
One paragraph. The symptom, and how to tell this case apart from the ones that
look like it. Name the error text, the log line, or the observable behaviour, so
someone can match it.

## What to check first
A short ordered list. The checks that decide which branch of the procedure you
are on, cheapest first. Each one says what its answer means.

## The procedure
Numbered steps, in order, each one an action. Name the file, the command, the
setting. Where a step is only needed in one of the cases above, say which.

## Traps
The things that have actually gone wrong, each with what caused it. One bullet
each.

## How you know it worked
The check that closes it — the command to run, the log line to see, the thing to
open. If the evidence does not say, write that it does not.

## What is not established
Anything a reader would reasonably expect here that the evidence does not cover.
Short. If nothing, write "Nothing — the evidence covers the procedure end to
end."
```

## Rules

- **Every specific claim carries its source**, inline: the note id in square
  brackets exactly as it appears, or the pull request as `repo#123`. A step with
  no source is a step you invented — cut it.
- **Never generalise past the instances.** Two instances are two instances. Write
  "both times" rather than "always"; write "in `scraphome#4120` and
  `scraphome#4180`" rather than "typically".
- **Never invent a file, a command, a flag, an error string or a number.** If the
  procedure needs a step the evidence does not describe, write the step as
  `TODO — the evidence does not say how` and move on. That line is useful. A
  plausible invention is worse than a hole, because the reader cannot tell.
- **No preamble, no closing summary, no praise.** Start at `## When you are in
  this case` and stop after the last section.
- Never include a credential, token, key, connection string, customer name or
  personal data, even if one appears in the evidence.
- Write in plain prose, second person, present tense. Short sentences. British
  spelling.
