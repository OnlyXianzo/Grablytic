---
name: write-in-my-style
description: Write and edit prose in the maintainer's own voice, learned from samples rather than guessed. Use when drafting release notes, docs, commit bodies, PR descriptions, or replies that should sound like this project's author and not like a chatbot.
metadata:
  trigger: Drafting or editing prose that carries the maintainer's voice
  author: Grablytic
  license_source: GPL-3.0, same as the repository
  upstream: none
  vendoring: written here, not imported. The voice is learned from this repository's own prose.
---

# Write in my style

Match the writing already in this repository instead of producing generic
documentation voice. The style lives in the prose the maintainer wrote, so read
it before writing anything.

There is no upstream for this skill. Anthropic publishes no skill by this name,
and the repositories that do use it learn from a sample you paste. This one
learns from the repository itself.

## Where the voice lives

Read a few of these before you write. Two or three sections is enough to catch
the rhythm; the whole file is not necessary.

| Source | What it shows |
|---|---|
| `README.md` | How the project talks to a stranger: claims, caveats, humour |
| `AGENTS.md`, "Writing style" | The explicit rules, which override anything you infer |
| `docs/*.md` (architecture, security, building) | Technical explanation at length |
| `docs/CHANGELOG.md` | How a change is described in one line and one paragraph |
| `.agents/vault/architecture/*.md` | Notes written for the next person, not for a reader |
| `git log --format=%B -20` | Commit bodies, which are prose too |

If the user supplies samples, those win over anything in the repository. Put
them in `.agents/voice/` and say so; that directory stays local and ignored.

## Build a profile before drafting

Write four or five lines for yourself, not for the reader:

1. **Sentence length.** Count words in three consecutive sentences. This repo
   mixes short declaratives with one longer explanatory sentence. Copy that.
2. **Openings.** Does a section start with the claim, or with a scene? Here it
   starts with the claim, and the caveat comes after.
3. **Endings.** Does a paragraph land on a fact or a flourish? Here it lands on
   a fact or a concrete next step.
4. **Punctuation.** Em dashes are rare and never used as rhythm. Colons open
   lists. Parentheses carry the aside that would otherwise interrupt.
5. **Vocabulary.** Plain verbs: takes, hands, keeps, writes, breaks. Words the
   maintainer avoids are listed in `AGENTS.md`.

If those five lines do not describe what you are about to write, you are
writing in the wrong voice.

## While drafting

- Address one reader. "You" for the person reading, "we" only for the project.
- Name the file, command, or test. A paragraph with no noun you can point at is
  usually filler.
- Keep the caveats. This project states what does not work; matching the voice
  includes matching the honesty.
- Leave the humour where it already is. Do not add jokes that were not there.
- Do not smooth a rough sentence into a brochure sentence. Rough and specific
  beats polished and vague.

## Before you hand it over

Run the text against `.agents/skills/stop-slop/SKILL.md` and
`.agents/skills/humanizer/SKILL.md`. Both are checks on the same problem: text that
sounds generated. This skill sets the target voice; those two remove what pulls
away from it.

Then read it out loud, or read the first sentence of every paragraph in order.
If the sequence sounds like a list of headings in prose, rewrite it.

## Must not

- Do not invent a style sample, and do not claim the maintainer wrote something
  they did not.
- Do not copy a phrase from the samples into new text where it does not fit.
  Voice is rhythm and word choice, not recycled sentences.
- Do not use this skill to write a person's opinion. If the source does not say
  it, you do not get to say it in their voice.
- Do not apply the style to code, config, or command output. Prose only.
