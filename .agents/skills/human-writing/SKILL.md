---
name: human-writing
description: "Voice and style rules for prose that reads like a specific person who knows the subject wrote it. Use for READMEs, docs pages, guides, tutorials, changelogs, release notes, project descriptions, blog posts, essays, newsletters, and documentary or video narration scripts. Load this whenever the user asks for any of those, asks to rewrite, polish, or humanize text, or says something sounds like AI, robotic, generic, corporate, or fluffy. Also load it before writing more than a few paragraphs of prose for a human reader in any context, even if the user never says 'human'. Does not apply to Reddit (use reddit-speak there) or to terse technical text like commit messages and code comments unless asked."
license: GPL-3.0
metadata:
  version: "1.0"
  author: OnlyXianzo
  platforms: linux, macos, windows
  provenance: generalized from reddit-speak v2.0.0
  scope: READMEs, docs, changelogs, blog posts, essays, narration scripts
---

# Human Writing

Writing that reads like one person who knows the subject wrote it for one specific reader.

Most text that sounds machine-made fails for a single reason. Nothing in it could only have come from someone who did the thing. It is generic and padded with importance, and it could be pasted into any other document about any other project. The fix is specifics and a voice, so that is what this skill enforces.

The goal is writing that is better for the reader. It does not plant typos or try to beat a detector. If a school, journal, or platform requires disclosure of AI help, follow that rule.

## When to load

Load this skill when:

- The user wants a README, docs page, guide, tutorial, changelog, release notes, project description, blog post, essay, newsletter, or narration script
- The user asks to rewrite, polish, or humanize text, or says it sounds like AI, robotic, generic, corporate, or fluffy
- You are about to write more than a few paragraphs of prose for a human reader

Skip it for Reddit (reddit-speak overrides this skill there) and for terse technical text like commit messages and code comments.

## Before you write

Answer these four. If you cannot, ask the user one short question instead of guessing.

1. Who reads this, and what are they trying to do right now?
2. What should they be able to do or say after reading?
3. What do I actually know that is specific? Commands, numbers, names, dates, failures, tradeoffs. If the answer is nothing, say what is missing. Do not pad.
4. Which genre section below applies?

## The voice

- Write as one person explaining something to a peer they respect. Skip the brand voice and the lecture.
- Use "I" when one person made the thing. Use "we" only when a team exists and the text is about the team.
- Plain words and contractions. A short sentence next to a long one. A fragment is fine when it lands.
- Say the thing, then stop.
- Give opinions as opinions, with the reason. Admit limits and tradeoffs early. Readers trust a writer who says what does not work.
- Let facts carry the feeling. Swap the adjective for the number, the example, or the command.

## Hard rules

### 1. Specifics over abstractions
Every paragraph needs something checkable: a command, a figure, a name, a date, a quote, a real example. Test each sentence by asking whether it could appear unchanged in a document about a different project. If it could, cut it or make it specific. "Handles large files well" becomes "Tested on a 4 GB file, which took six minutes on a home connection."

### 2. No hype or emotional inflation
Cut amazing, incredible, exciting, game-changing, revolutionary, powerful, seamless, robust, comprehensive, cutting-edge, next-generation, blazing fast, effortless, best-in-class. Say what the thing does and let the reader decide it is good.

### 3. No self-praise
Never call your own work the best, the most complete, unique, or innovative. Evidence is fine: a benchmark, a comparison with numbers, a real user quote with attribution.

### 4. No significance inflation
Cut "plays a pivotal role", "is a testament to", "stands as", "in the ever-evolving landscape of", "a rich tapestry", "journey", "unlock the power of". Facts do not need an announcer.

### 5. No negative parallelism
Never write "not X, but Y", "not just X, it's Y", "it's not about X, it's about Y", or "no X, no Y, just Z". State the positive claim directly.

### 6. Break the rule of three
Reflexive triples ("fast, reliable, and secure", "plan, build, and ship") are the most common tell, along with three parallel clauses in a row. List what is true, which is often two items or four. If three really is the count, vary their shape and length.

### 7. No em dashes
Use a period, comma, colon, or parentheses. This rule is mechanical, so check for it on every pass.

### 8. No throat-clearing and no tidy endings
Cut openers like "In today's fast-paced world", "Let's dive in", "Whether you're a beginner or an expert", "It's worth noting that". Cut closers like "In conclusion", "Overall", "I hope this helps", "Happy coding". Start with the content and stop when it is done.

### 9. No announcing, no echoing
Do not say what a section will cover before covering it, and do not summarize it afterwards. One statement per idea.

### 10. No scaffolding phrases
Cut "Here's the thing", "Here's the kicker", "Let that sink in", "Spoiler:", and the pattern of a rhetorical question followed by its answer ("The result? Faster builds."). Ask a question only when you want the reader to think about it.

### 11. Plain vocabulary
leverage and utilize become use. Delve into becomes look at. Navigate (figurative) becomes deal with. Foster and harness become build or use. Streamline becomes simplify or speed up. Facilitate becomes help or let. Ensure becomes make sure. Crucial and pivotal become important, or get cut. Myriad and plethora become many. "A variety of" becomes the actual list. For seamless and robust, say what actually works or what it survives.

### 12. Vary rhythm and shape
If three sentences in a row share a length or structure, rewrite one. Mix paragraph lengths. Sections should be as long as their content needs, not all built from the same intro, three bullets, and a summary line.

### 13. Hedge once, where you are unsure
Do not soften every claim with "may", "can", "typically", "generally". Do not claim certainty you lack either. Mark the doubtful spot once and say what you would check.

### 14. Restrained formatting
Headings in sentence case that name the content ("Install", "Known issues"). No emoji in headings or bullets. No exclamation marks outside quoted speech or UI strings. Bold only for UI labels and warnings, never for emphasis in prose. Bold-label bullets ("**Fast:** ...") only in real definition lists. Use lists and tables when the content is a list or a table, like install steps or an options reference, and prose when it is an argument.

### 15. Show the rough edges
Say what is unfinished, unsupported, slow, or likely to break. A limitations section earns more trust than any feature list.

### 16. Real examples
Use realistic names, paths, values, and output, ideally from something that was actually run. Use reserved placeholders (example.com, 192.0.2.1) where convention calls for them. Avoid foo and bar when a real case is available.

## Genres

### README

Order: what it is, why it exists, how to install it, the smallest working example, options, limits, license.

```
# project-name
One sentence on what it does and who it is for.

A short paragraph on why it exists. First person if one person built it.
Name the obvious alternative and say where this differs.

[screenshot or demo]

## Install
## Usage
## Options
## Platform support and known issues
## Contributing
## License
```

- The first sentence says what the tool does. Before: "A powerful, seamless tool that revolutionizes your workflow." After: "Renames photos by their EXIF date. Single binary, no config."
- List features as things the reader can do ("Download whole playlists"). Skip adjectives.
- Run every command you put in the README. Show the real output of the usage example.
- Keep badges few and factual (build status, version, license).
- Say what platforms and versions you tested on. Do not write "production-ready" unless someone runs it in production, and then say who.

### Docs (tutorial, how-to, reference, explanation)

Pick one type per page and keep to it.

- Tutorial and how-to: title names the task ("Back up the database"). Prerequisites first. Numbered steps, one action each, imperative voice, expected output after any step that can fail. Warn before the dangerous step, not after.
- Reference: complete, consistent, terse. Tables are fine. No narrative.
- Explanation: prose. Cover why it works this way and what the tradeoffs are.
- Use exact names: file paths, flags, and error messages verbatim. Put anything the reader types in a code block.
- Define a term once, at first use. Link to other pages instead of re-explaining.
- Docs keep their lists, numbered steps, and code blocks. The no-bullets habit from other voice skills does not apply here.

### Changelog and release notes

- Write from the user's side: what they can now do or what stopped breaking.
- Breaking changes go first, each with the one-line migration step.
- One line per change, grouped (Added, Changed, Fixed). Link the issue or PR number. Credit contributors by name.
- No "exciting new" and no "we're thrilled".

### Blog posts and essays

- Open with the specific thing that happened or the claim you are making, not with why the topic matters.
- One argument per post. Include the part that went wrong.
- End on the last useful thing. No moral, no summary of what you just said.
- First person. Sentence-case title that names the actual subject.

### Documentary narration and video scripts

Write for the ear, and read every line aloud before keeping it.

- Short declarative sentences. Concrete nouns, active verbs. One idea per sentence, nothing you cannot say in one breath.
- Put the image or fact first and let the viewer supply the feeling. The narrator never announces significance. Before: "Nestled in the mountains, the village stands as a testament to resilience." After: "Eleven families live here, above the tree line. Snow closes the only road from November to April."
- Names, dates, places, and numbers. Round the numbers so they can be spoken.
- Skip parentheses, semicolons, stacked clauses, and acronyms nobody says aloud.
- Vary sentence length for pacing. Leave room for footage and silence, and mark it in the script ([beat], [B-roll: ...]).
- Let people speak for themselves. Quote interviewees directly and attribute them.
- Open on a scene, not a thesis. End on an image or a fact, not a recap of themes.
- Add pronunciation in brackets for unusual names.

### Anything else

Pick the nearest genre above and apply the hard rules.

## Patterns that work

- Open in the middle of the thing: what you did, noticed, or got stuck on.
- Admit a failure early. "I got this wrong the first time" buys more trust than any credential.
- One light self-deprecating joke, once, if it is true.
- Questions only when you want an answer.
- Let sentences run the way speech runs, then cut what the ear does not need.
- Concrete beats clever.

## Readers dislike

- [ ] Corporate speak ("we're excited to", "thrilled to announce")
- [ ] Hype adjectives and self-praise
- [ ] Em dashes, rule-of-three lists, negative parallelism
- [ ] Openers that stall and closers that recap
- [ ] Sections that all have the same shape
- [ ] Claims with nothing behind them
- [ ] Hedging on every line
- [ ] Emoji and exclamation marks in technical writing
- [ ] Walls of text with no depth, and short text with no substance

## Readers like

- [ ] A person's voice ("I noticed", "I kept hitting")
- [ ] Specific commands, numbers, names, and dates
- [ ] Honest limits and tradeoffs
- [ ] Examples from real use
- [ ] Plain words, with jargon explained at first use
- [ ] Length that matches the content
- [ ] Rhythm that sounds spoken

## Integration

- If `reddit-speak` is installed, it overrides this skill for anything posted on Reddit.
- If `humanizer` or `write-in-my-style` are installed, load them alongside this one. Their voice rules win where they conflict with the voice section here. The genre rules still apply.

## Self-check before sending

1. Could any sentence appear unchanged in a document about a different subject? (Make it specific or cut it.)
2. Is there anything checkable in every paragraph?
3. Any em dashes? (Fix them.)
4. Any "not X, but Y" or "no X, no Y, just Z"? (State the positive claim.)
5. Any reflexive triples? (Cut to what is true.)
6. Any hype words or self-praise? (Say what it does.)
7. Any opener that stalls or closer that recaps? (Delete it.)
8. Do the sections all have the same shape? (Change one.)
9. Do the genre conventions hold: commands run, steps numbered, scripts readable aloud?
10. Are the limits and rough edges stated?
11. Would a reader think a specific person who knows this wrote it? If not, rewrite.
