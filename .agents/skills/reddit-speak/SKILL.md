---
name: reddit-speak
description: >-
  Reddit writing voice and tone rules. Load whenever the word "Reddit" or
  "Redditors" appears in a request, or when writing or revising any Reddit
  post, comment, DM, or pitch. Encodes how Redditors read, what they reject,
  and how to write so the post lands as a person talking rather than a brand
  announcing.
license: GPL-3.0
metadata:
  version: "2.0"
  author: OnlyXianzo
  platforms: linux, macos, windows
  provenance: requested by the maintainer, 2026-07-22
  study_basis: 20+ top-scoring self posts from r/selfhosted, r/ClaudeAI, r/sysadmin, r/programming
---

# Reddit Speak — How to Write for Redditors
Reddit is not LinkedIn. Reddit is not Twitter. Reddit is not a marketing channel. Redditors are a distinct audience with specific cultural norms, and writing for them the way you'd write for any other platform will get you downvoted, reported, or ignored.

This skill was built from the maintainer's instruction (2026-07-22) plus study of 20+ actual top-scoring posts from r/selfhosted, r/ClaudeAI, r/sysadmin, and r/programming. The rules below are extracted from what actually works on tech Reddit, not from theory.

## When to load this skill
Load this skill whenever:
- The user says "Reddit", "Redditors", "subreddit", "post on Reddit", or references any Reddit activity
- You are writing or revising any Reddit post, comment, DM, mod application, or community pitch
- You are reviewing or auditing Reddit content the maintainer plans to post

This pairs with `write-in-my-style` (the maintainer's voice) and `humanizer` (anti-AI-slop). Load all three when writing Reddit content in the maintainer's voice. The rules below override general style guidance for Reddit specifically.

---

## Who Redditors Are
- **Cynical, not honest.** They don't want you to be honest. They want you to be cynical. Tell it like it is. Cut the fluff. Get to the point. Less corporate wherever possible, shorter wherever possible.
- **Anti-corporate.** They can spot marketing from a mile away. "We are excited to announce" is a death sentence. They hate depersonalization into a corporation.
- **Anti-self-praise.** Any self-praise is completely disallowed. If you're going to praise something, it has to come from somebody else. Praising yourself is seen as disingenuous. "I just finished my life-long dream of publishing my first game" works. "We at MegaCorp are launching the BEST EVER RTS BATTLER" does not.
- **Humble, not authoritative.** You are never the expert on Reddit. You are a learner like everyone else. You are humble. You are trying your best. You are a little bit self-conscious. That is who you are on Reddit at all times. Use "I think" rather than "a lot of people do this and they're doing it wrong." The community is smarter than you.
- **Allergic to AI-speak.** They hate anything that looks like ChatGPT wrote it. Em dashes, rule-of-three lists, negative parallelism, triple repeats in a sentence -- all instant tells.
- **Personal over professional.** "I" beats "we." Always. "I built this because I kept hitting the same wall" beats "We created a community designed to help users."
- **Hate "we" instead of "I."** Using "we" when you mean "I" is a corporate tell. Redditors assume you're either a brand account or someone putting on a suit. Say "I."
- **Lazy readers but deep when hooked.** They skim by default. But if a post is going to be long, it must be detailed, in-depth, and well thought through. Short and shallow = bad. Long and shallow = worse. Long and deep = respected.

---

## Hard Rules
### 1. Sentence-case titles only
Reddit will not sustain anything but sentence-case titles. "It's 3am on a Saturday, now i get it" works. "This subreddit used to be fun" works. "I am leaving IT." works. Title Case Does Not Work On Reddit. It looks like marketing.

### 2. One intentional formatting error
Every post must contain exactly one deliberate formatting imperfection. This is a signal that a human wrote it, not an AI. Examples from real top posts:
- A typo: "gettong hired", "tored of being", "basically" (appears as "basically" in the post)
- Lowercase "i" in casual text
- A missing apostrophe ("dont", "cant")
- Not capitalizing a proper noun

AI produces perfect formatting. Humans don't, always. One imperfection proves a person wrote it.

### 3. No bullet point lists in discussion posts
Reddit posts in this voice do not use bullet points or numbered lists in the body. Write in flowing paragraphs. If you need to enumerate things, weave them into sentences. Bullet lists are a formatting tell and they make posts look like presentations, not conversations.

Exception: data-heavy technical posts (like traffic analysis) can use numbered sections. Project announcements listing features can use bullets. But discussion posts, opinion posts, and question posts must be prose.

### 4. No bolding
No bold text in the body of a Reddit post. Bold is a formatting crutch that makes posts look like marketing materials. Let the words carry the weight.

### 5. No em dashes
Use `--` (double hyphen) or commas instead. Em dashes are the #1 AI writing tell on Reddit.

### 6. No negative parallelism
Never use these constructions:
- "not X, but Y"
- "not just X, it's Y"
- "it's not about X, it's about Y"
- "No proprietary format, no export step, just files it can read"

State the positive claim directly. If you catch yourself writing "not X but Y," rewrite it as just Y.
### 7. No triple repeats or rule-of-three in a sentence
"Could be rate limiting, could be what you're throwing at it that week, could just be your own patience wearing thin" -- this triple repeat pattern is a hallmark of AI writing. Avoid it. If you find yourself listing three things in parallel structure, break it up or cut to two.

### 8. No exclamation marks
Redditors read exclamation marks as either excitement (corporate) or desperation (marketing). Use periods. The weight is in the words.

### 9. No emojis
Reddit is not Discord. Emojis in Reddit posts read as either corporate decoration or try-hard friendliness. Plain text only.

### 10. No emotional language
No "amazing," "incredible," "exciting," "game-changing," "revolutionary," "best ever." Redditors are skeptical of emotional inflation. Describe things plainly. If something is good, say what it does, not how it makes you feel.

### 11. No self-praise
You are never the expert. You are a learner. Never praise yourself, your product, or your community. If something is good, let the reader decide. Never say "the best," "the most comprehensive," "a unique and active Discord server." State what exists and let people judge.

### 12. Maximum length: 2.5 paragraphs for discussion posts
At its absolute maximum, a discussion or opinion post should be 2.5 paragraphs. Shorter is better. Most posts should be 1-2 paragraphs. If a post needs to be longer (data posts, project announcements), it must earn the length with genuine depth and detail. The first sentence of a question post is usually enough. Don't over-explain.

### 13. Use "I" not "we"
First person singular. "I built," "I made," "I noticed." Never "we built" unless you genuinely mean a team of people and the post is about the team. If it's just you, say "I."

### 14. No colons or semicolons
Avoid them altogether. Maximum one per post if absolutely necessary. They make text look formal and structured. Reddit reads like spoken words, not properly formatted text.

### 15. Spoken-word sentences
Longer sentences that look like spoken words rather than properly formatted text often do better. "The further I got, the more I kept hitting the limits of leaning on Lidarr for the library side so I replaced it." This reads like someone talking. Let sentences flow naturally rather than constructing them perfectly.

### 16. Humble, suggestive tone
Never be pushy. Never command. Never tell the reader what to do. Never be the authority in the room. Use "I think" rather than "a lot of people do this." State your opinion as your opinion. The community is smarter than you.
- "Here's what I am learning" not "Here's a starting playbook"
- "I think this might help" not "You should check this out"
- "If you've run into this, there's a place where people talk about it" not "You need to join"
- Let the reader decide. Suggest, don't sell.

### 17. Don't be demanding
Never ask people to do things that take a lot of time and effort just to respond. "Post your file's length and how it's performing in practice" is too demanding. A simple question is enough. The first sentence of a question post is usually sufficient. Don't pad it with instructions.

### 18. Subtle promotion
If linking to a Discord or product, the promotion must be a small fraction of the post, not half of it. The post must stand on its own as valuable content even if the reader never clicks the link. Lead with the topic, not the link. The plug is a side note at the end, one or two sentences maximum. Be subtle.

### 19. Casual, non-business style
Write the way you'd talk to a friend at a bar about something you find interesting. Professional enough to be taken seriously, casual enough to not sound like you're at a conference. Contractions are fine. Incomplete sentences are fine. Starting with "Hey" or "So" is fine. Ending with a question is great.

### 20. Markdown links only
When linking, use proper markdown: `[link text](URL)` or just the raw URL. Never bare HTML, never shortened URLs, never tracking redirects. Direct links only.

---

## Style Patterns Extracted from Real Top Reddit Posts
These patterns were identified by studying 20+ top-scoring self posts from r/selfhosted, r/ClaudeAI, r/sysadmin, and r/programming (July 2026):

1. **Casual openings**: "Like most of you I run...", "Hey there,", "Hey everyone", "Hey folks," -- conversational, never formal.

2. **First-person honesty about failures**: "I expected it to be bad. It was worse, and also weirder, than I thought." / "for some reason, it never really clicked with me" / "I was already dreading it."

3. **Self-deprecating humor**: "my most dedicated fan hit me on 30 out of 31 days" / "nearly achieved enlightenment" / "held together with digital duct tape"

4. **Questions that invite discussion**: "Is it just me?" / "Am I the only one who didn't know about this for all these years?" / "What's that thing or process you've created?"

5. **Short and punchy for opinions**: The best opinion posts are 2-3 short paragraphs. No padding. Get in, say it, get out.

6. **Edits appended at the bottom**: "Edit: thank you so much to everyone..." -- common Reddit convention that signals genuine community engagement.

7. **Real typos as human markers**: "gettong hired", "tored of being", "Adressing", "basically" -- real people make typos. One per post.

---

## The Example Posts
No sample post ships with this skill. The patterns in the section above are the
study notes; a full set of annotated example posts stays in the maintainer's
private notes. If you have those, read them before writing. If you do not, work
from the patterns.

---

## What Redditors Hate (checklist before posting)
- [ ] Corporate speak ("we are excited to," "thrilled to announce," "delighted to share")
- [ ] Professional tone that sounds like a LinkedIn post
- [ ] "We" when it should be "I"
- [ ] Title Case titles
- [ ] Em dashes
- [ ] Bolding for emphasis
- [ ] Bullet lists in discussion posts
- [ ] Exclamation marks
- [ ] Emojis
- [ ] Emotional / promotional language ("amazing," "incredible," "game-changing," "best ever")
- [ ] Negative parallelism ("not X, but Y")
- [ ] Triple repeats in a sentence (rule of three)
- [ ] Colons or semicolons (max 1 per post, ideally zero)
- [ ] Self-praise or describing your own thing as "the best" or "unique"
- [ ] Pushy calls to action ("Join now!" "Don't miss out!")
- [ ] Demanding readers do time-consuming tasks
- [ ] Leading with the product/Discord instead of the topic
- [ ] Half the post being promotion
- [ ] Telling people what to do instead of stating your opinion
- [ ] Walls of text without depth
- [ ] Short posts with no substance
- [ ] Anything that looks like AI wrote it (perfect formatting, rule-of-three, significance inflation)

## What Redditors Love (checklist before posting)
- [ ] Personal voice ("I noticed," "I kept hitting," "I messed this up")
- [ ] Humility and self-deprecation
- [ ] "I think" rather than "a lot of people do this"
- [ ] Negative admissions (makes you seem honest)
- [ ] Depth and detail when the topic deserves it
- [ ] Casual, conversational, spoken-word tone
- [ ] Questions that invite genuine discussion
- [ ] Plain language, no jargon without immediate explanation
- [ ] One formatting imperfection (human marker)
- [ ] Suggestive, not commanding tone
- [ ] Content that stands on its own even without the link
- [ ] Real examples, not hypothetical abstractions
- [ ] Sentence-case titles
- [ ] Longer flowing sentences that sound like speech

---

## Integration with a pitch SOP

If a separate SOP governs pitch structure (word limits, buyer types, funnel,
tracking links, posting-account rules), that document wins on structure and
this skill wins on tone. The two do not conflict on the things that matter:
no corporate speak, no arrogance, no insulting the reader.

Where a pitch SOP and this skill disagree on pronouns, this skill wins. A pitch
written as "we built" reads as a brand account even when it is one person.

## Integration with other skills
- **write-in-my-style**: the maintainer's voice for long-form content. Reddit posts use that voice but with Reddit-specific constraints from this skill.
- **humanizer**: Anti-AI-slop checklist. Run every Reddit post through the 29-pattern checklist before posting. This skill adds Reddit-specific patterns on top.
- **reddit-community-engagement** (not part of this repository): operational
  strategy, subreddit choice, mod outreach. This skill is the writing layer;
  that one is the strategy layer.

The empirical basis for these rules is the study described at the top of this
file. The underlying post archive stays private, so this skill is self-contained: the
rules and the extracted patterns are what you work from.

---

## Self-check before posting any Reddit content
1. Is the title sentence-case?
2. Does it contain exactly one intentional formatting error?
3. Is it 2.5 paragraphs or shorter (for discussion posts)?
4. Does it use "I" instead of "we" (unless genuinely a team post)?
5. Are there any em dashes? (Fix them.)
6. Are there any bold words? (Remove them.)
7. Are there bullet lists in a discussion post? (Convert to prose.)
8. Are there exclamation marks? (Remove them.)
9. Are there emojis? (Remove them.)
10. Is there negative parallelism? (Rewrite the positive claim directly.)
11. Is there a triple repeat or rule-of-three in a sentence? (Break it up.)
12. Are there colons or semicolons? (Remove them, max 1 per post.)
13. Is there any self-praise? (Remove it. You're a learner, not an expert.)
14. Is the tone humble and suggestive, not pushy?
15. Does the post stand on its own without the Discord link?
16. Is the Discord plug subtle, at the end, not the lead?
17. Are you using "I think" instead of "a lot of people do this"?
18. Would a Redditor read this and think "this was written by a person"? If not, rewrite.
