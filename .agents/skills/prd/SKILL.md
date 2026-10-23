---
name: prd
description: Write a product requirements document for a feature of this backend in docs/prd/<feature>.md, from an idea or a grilling session. Settles open decisions first, states rules a backlog can be cut from, and lists what is out of scope. Use when asked for a PRD, a spec or requirements, or before planning a feature that spans several stories.
---

# Write a PRD

A PRD holds the why and the rules of a feature. It is not the backlog: Given/When/Then criteria, `owns` and test filters live in the stories the `backlog` skill cuts from it. For a change of one to three stories, skip the PRD and use `backlog` directly.

## 1. Settle the decisions
List what the idea leaves open: roles and who may do what, the states a thing moves through, what each error returns, what is out of scope, anything that needs a new package, a secret or infrastructure. Put the open ones to the user with the `grilling` skill. Look up facts in the repo yourself instead of asking.

When the user says to use defaults, take your recommended answer for each open decision and list it under Assumptions, so a guess never reads as a decision.

## 2. Write `docs/prd/<feature>.md`
Use a kebab-case file name and the template below. Keep only sections with content, except Open questions.

- Each functional requirement has a heading `### FR-<n> <name>`. Stories cite it as `docs/prd/<feature>.md#FR-<n>`, and an agent working the story reads only that section. Never renumber; mark a dropped requirement "Removed" instead.
- State each requirement as rules a test can check: who may do what, which state changes are allowed, and which error each refusal returns. Use the repo's mapping: 400 invalid input, 401 no identity, 403 not allowed, 404 not found, 409 not allowed in the current state.
- Give every non-functional requirement a number or a check, such as "every state change records who made it and when".
- Stay inside the stack in `ARCHITECTURE.md`: a backend API in the Clean Architecture layers, Dapper, `ErrorOr`. Anything that needs a new NuGet package, a secret or infrastructure goes under "Needs approval" with the reason, because `AGENTS.md` requires asking first.
- Write for a reader with no context. Define each domain term once, under Concepts and states.

```markdown
# <Feature name>

## Overview
<Two or three sentences: what it is and who it serves.>

## Problem
<What goes wrong today, for whom.>

## Goals
- <A measurable outcome.>

## Users and roles
| Role | May |
|---|---|

## Concepts and states
<Each entity with its key fields. State changes as text, for example: Draft -> Submitted -> Approved, Submitted -> Returned -> Draft.>

## Functional requirements
### FR-1 <name>
<Rules, and the error each refusal returns.>

## Non-functional requirements
- <Requirement with a number or a check.>

## Out of scope
- <What this feature does not do, and why.>

## Needs approval
- <Package, secret or infrastructure, and why it is needed.>

## Decisions
- <Decision>: <why>. Rejected: <alternative>, because <reason>.

## Assumptions
- <Default taken without the user's answer.>

## Open questions
- None.
```

## 3. Finish
- Open questions is "None.", or it says which requirements wait on which question. The `backlog` skill does not cut stories from a requirement that waits on a question.
- Add a line to `PROGRESS.md` naming the PRD and what comes next (usually the `backlog` skill).
- Commit and open a pull request with the `ship` skill only when the user asks. A person approves the PRD in that pull request.
