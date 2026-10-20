---
name: studio-critic-loop
description: >-
  Use when a Flutter screen needs to reach a top-studio quality bar, or when a
  redesign looks generic or AI-generated, or when asked to critique, polish,
  score, or iterate on a UI screenshot. Runs a closed loop: render the screen at
  a fixed viewport, send only the raster to a fresh critic subagent, fix one
  variable per round, and repeat until the critic scores at least 9.0/10. Works
  on any Flutter app, not only Grablytic.
---

# Studio Critic Loop

A repeatable design-improvement loop. An isolated critic decides when the work
is done. It never sees the code, the intent, or the target score.

Set these once before starting:

```bash
REPO_ROOT="${REPO_ROOT:-$HOME/grablytic}"   # ask the user if this is wrong
```

If `$REPO_ROOT` does not exist, stop and ask the user where the project lives.
Do not guess and do not hardcode a personal path into a tracked file.

---

## 1. Core principle

> The author never grades their own work.

A critic that sees the diff will rationalise the diff. A critic that sees the
target score will grade to the target. A critic that sees earlier rounds will
anchor on them and stop finding new faults.

---

## 2. When to use

Use it for:

- A new screen before it is called finished.
- A screen described as generic, cheap, or AI-looking.
- A redesign where the author is invested in the result.
- A theme change that may have regressed existing screens.

Do not use it for:

- Logic bugs. Use a normal reproduction and test.
- Engine, IPC, or native layer problems. Use `verified-implementation`.
- Accessibility conformance on its own. The critic will flag contrast and tap
  targets, but it is an aesthetic grader, not an audit.

---

## 3. Prerequisites

- Flutter on `PATH` (`flutter`, `dart`).
- Real fonts bundled in `assets/fonts/`. A render with missing fonts is tofu,
  and the critic will review the wrong thing.
- A deterministic capture test. If the repo does not already have one, create
  `test/capture_<screen>_test.dart` using the template in section 4.

For Grablytic specifically, the bundled families are Bricolage Grotesque
(headings), Figtree (body), and IosevkaCharonMono (numbers and telemetry).
Load them from `assets/fonts/` in the test; do not rely on a system font. The
sample below imports Grablytic's package. If you use this skill in another
Flutter app, swap the import and the provider override for that app's
equivalents.

---

## 4. Capture harness

Create one test per screen under review. Keep the viewport, device pixel ratio,
fonts, and mock data fixed across every round.

```dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';

void main() {
  testWidgets('capture screen', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues({});

    final key = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          engineProvider.overrideWith((ref) => MockEngineService()),
        ],
        child: RepaintBoundary(
          key: key,
          child: const MaterialApp(home: YourScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes != null) {
        File('test_screenshot.png').writeAsBytesSync(
          bytes.buffer.asUint8List(),
        );
      }
    });
  });
}
```

Adjust the import and the override to match the repo. If the screen needs
providers beyond the engine, override them with fixed mock values. Do not use
live network data.

Non-negotiable conditions:

- Fixed viewport and DPR.
- Fixed, realistic mock data: long titles, real percentages, missing metadata.
- Fonts loaded from the repo's `assets/fonts/`.
- Look at the PNG yourself once before the first critique. A blank, clipped, or
  overflowing raster means the harness is broken.

`test_screenshot.png` is scratch output. Add it to `.gitignore`; never commit it.

---

## 5. The loop

### Step 1: Render

```bash
cd "$REPO_ROOT"
flutter test test/capture_<screen>_test.dart
```

### Step 2: Isolate the critic

Spawn a fresh subagent whose entire input is the screenshot path and the prompt
in section 6. Pass nothing else. No code, diff, test output, design intent,
prior review, or the word "improve".

### Step 3: Collect the critique

Require itemised gaps, each naming a concrete element and a concrete fix, then a
single score out of 10.

### Step 4: Fix one variable

Take the highest-severity gap. Change only that. Batched changes make the next
score uninterpretable, because you cannot tell which edit moved the number.

### Step 5: Re-render and re-critique

Repeat steps 1 through 4. Record each round in
`$REPO_ROOT/.agents/design-critic-log.md`. That file is local and ignored by
git.

### Step 6: Stop

Stop only when a fresh critic scores at least 9.0/10. If you stop early because
of budget or scope, say so and record the final score. A silent stop looks like
a pass.

---

## 6. Critic prompt

Send this verbatim, substituting only the path:

```
Please review the design in the screenshot located at `{{SCREENSHOT_ABSOLUTE_PATH}}`
(use the view_file tool to inspect it).

Evaluate the aesthetic that the design is going for, imagine how a top design
studio would execute this aesthetic, then outline the biggest gaps.

Lastly, provide a score out of 10 indicating how close the current design is to
that studio-level quality bar.

Guidance:
- Think high-level about the overall structure and composition as well as look at
  the fine details.
- Watch out for patterns that feel overdone, excessive, or otherwise obviously
  AI-generated, and penalize them.
- Provide tight, specific feedback, not vague prose.
- Be bold and opinionated, not relying on what's safe or easy.
```

Do not add "you must reach 9", "here are the known problems", or "be
constructive". Each addition leaks intent and softens the grade.

---

## 7. Isolation rules

| Rule | Why |
|---|---|
| Fresh subagent every round | Carried context anchors the critic to earlier rounds |
| Only the raster path in the prompt | Code invites rationalisation |
| Never reveal the threshold | The critic starts grading to the target |
| Never reveal prior scores | The critic defends its past verdict |
| One variable per round | Score changes stay attributable |
| Fixed viewport and mock data | Otherwise you compare two different screens |

The target is 9.0/10. Keep it in the driver prompt and in your local log. Never
put it in the critic prompt. If you change the target, change it between rounds.

---

## 8. Fix vocabulary

These are the changes that usually move the score.

### 8.1 Tonal steps, not floating white cards

Build surfaces from a warm tonal ladder and let the step create depth. Avoid a
pure white container on a cream canvas, and avoid grey borders as the only
separation. Example ladder:

```
#FAF6F0 -> #F6F0EA -> #EFE8E1
```

Use optical gutters and hairline warm borders. Do not stack shadows to fake
material.

### 8.2 Dock the controls

Scattered filter pills read as an e-commerce toolbar. Unify related controls
into one physical console: an omnibar with a docked segmented shelf. If a
control floats, ask what it should be docked into.

### 8.3 Show provenance

Every media row earns trust with evidence: source badge, duration, resolved
codec and quality, file size. Never show a number the app cannot actually
produce.

### 8.4 One anchor metric per card

Percentages, speeds, ETAs, and sizes belong in tabular monospace. Pick one bold
anchor number per card and make the rest secondary. Two competing percentages
is the most common critic complaint.

---

## 9. Anti-slop checklist

Run this before every re-render.

- [ ] No pure white container on a warm canvas.
- [ ] No pill inside a pill.
- [ ] No rounded button floating inside a rounded input.
- [ ] No default Material accent surviving in a custom palette.
- [ ] No uppercase tracked eyebrow paired with a dropdown pill.
- [ ] No radial blobs or generic mesh gradients as decoration.
- [ ] Exactly one anchor metric per card.
- [ ] Controls are docked, not scattered.
- [ ] Tap targets at least 48dp.
- [ ] Body text at least 14sp with real contrast on the surface it sits on.

---

## 10. Failure modes

- **Score stuck around 5.2 to 5.5.** Cosmetic edits are masking a structural
  or colour-token problem. Change structure, not surface.
- **Critic asks for physical container geometry.** Wrapping widgets in more
  `Container`s without changing the tonal step does not answer it.
- **Badge colour clashes.** A semantic green badge on a warm palette looks
  foreign. Derive badges from the theme ramp.
- **Titles wrap to five or six lines.** Cut competing anchors before shrinking
  type.
- **Hallucinated counters.** A percentage next to a container with no byte
  total. Remove the number; do not invent one.

---

## 11. Driver prompt

Paste this to start the loop. It configures the main agent, not the critic.

```
I want you to improve this screen's design. Use a subagent as a design critic.

At each iteration:
- Capture a screenshot of the current screen.
- Invoke the critic in a fresh context with only the screenshot. Do not pass the
  code, the diff, implementation details, or earlier critiques.
- Ask it to evaluate the aesthetic the design is going for, imagine how a top
  design studio would execute it, and list the biggest gaps.
- Ask for a score out of 10 for how close the current design is to that bar.

Tell the critic to:
- Judge both overall composition and fine detail.
- Penalise patterns that feel overdone or obviously AI-generated.
- Give tight, specific feedback, not vague prose.
- Be opinionated rather than safe.

Your work is complete only when a fresh critic scores 9/10 or higher. Do not put
that criterion in the critic prompt. Use the same critic prompt every round.
```

Two prompts, two audiences:

| Prompt | Audience | Contains 9.0? | Contains code or prior scores? |
|---|---|---|---|
| Driver prompt | Main agent | Yes | Yes |
| Critic prompt | Isolated critic | No | No |

The driver needs the goal to know when to stop. The critic must not have it, or
the score stops measuring anything.

---

## 12. Adding a variant

If you reword the driver prompt, keep these invariants:

1. The completion criterion lives in the driver prompt only.
2. The critic prompt text is identical every round.
3. The critic receives the screenshot path and nothing else.
4. One variable changes per round.
5. The viewport and mock data never change mid-loop.

After spawning the critic, re-read what you actually sent. One extra sentence
such as "this is the home screen" or "aim for 9" invalidates that round, and it
is easy to miss.
