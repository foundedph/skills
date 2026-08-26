# course.json Format — the lesson pack manifest

`course.json` lives at the workspace root. It is the **machine-readable** view of a
teaching workspace: the same lessons the `./lessons/*.html` files present to a human,
expressed as structured data so another system can ingest the course.

The HTML lessons remain the primary artifact — beautiful, self-contained, meant to be
opened in a browser. `course.json` does not replace them. It exists because the HTML has
no declared structure: its section headings, do-steps, callouts and quiz blocks are an
emergent habit of one generation run, not a promise. Anything downstream that scrapes
those class names breaks silently the first time a lesson is written differently.

Write `course.json` whenever the workspace is being handed to another system — an LMS, a
course platform, a colleague's tooling. It is not needed for solo learning.

## Why the body is markdown inside JSON

The lesson body ships as a **markdown string inside the manifest**, not as HTML and not
as sibling `.md` files.

- Markdown, not HTML: a consumer that must store or re-render the prose would otherwise
  need an HTML-to-markdown converter and inherit a lossy conversion step it did not ask
  for. Emitting markdown moves that work to the side that already knows what the prose
  means.
- Inside the JSON, not sibling files: one file to read, one thing to version, no way for
  a body to drift out of sync with the manifest entry that describes it.

The HTML lesson is still referenced by path so a consumer can link to or embed the pretty
version. It is never parsed.

## Template

```json
{
  "packFormat": 1,
  "title": "Todoist for real life",
  "slug": "todoist-for-real-life",
  "mission": "# Mission: Todoist\n\n## Why\n…full verbatim MISSION.md…",
  "modules": [
    {
      "title": "Getting set up",
      "description": "One-line summary of what this group of lessons covers.",
      "lessons": [
        {
          "title": "Sign up and meet your inbox",
          "slug": "0001-sign-up-and-meet-your-inbox",
          "html": "lessons/0001-sign-up-and-meet-your-inbox.html",
          "estimatedMinutes": 6,
          "body": "## Why the inbox matters\n\nEverything you capture…",
          "keyConcepts": ["Inbox", "Quick Add"],
          "links": [
            { "label": "Todoist Quick Add reference", "url": "https://…", "type": "reference" }
          ],
          "quiz": [
            {
              "prompt": "The Today tab shows tasks…",
              "options": [
                { "text": "Only from your personal projects", "correct": false },
                { "text": "Due today, across every project you have", "correct": true }
              ],
              "explanation": "Today is a cross-project view, not a project filter."
            }
          ]
        }
      ]
    }
  ],
  "glossary": [
    {
      "term": "Inbox",
      "definition": "The default capture bucket every unfiled task lands in.",
      "avoid": ["Capture list", "Dump"]
    }
  ]
}
```

## Field rules

### Top level

- **`packFormat`** (required, integer). `1` today. Increment only for a change that a
  version-1 consumer cannot read. Consumers are asked to warn-and-continue on an unknown
  version rather than refuse, so additive changes must never need a bump.
- **`title`** (required). The course title, learner-facing.
- **`slug`** (required). Dash-case, stable across regenerations of the same course.
- **`mission`** (required). The **entire `MISSION.md` verbatim**, markdown and all. Do not
  summarise or restructure it — the consumer decides how much to surface. A workspace with
  no `MISSION.md` is not ready to be packed; write the mission first.
- **`modules`** (required, ordered). See below.
- **`glossary`** (optional). The workspace glossary as data. Terms only — one entry per
  `**Term**:` block in the glossary, with its aliases in `avoid`.

### Modules

**Group the lessons yourself. Do not emit a flat list.** Lesson file numbering carries the
teaching order but not the arc — which lessons form a phase, where one body of skill ends
and the next begins. That judgment belongs to whoever taught the course, and a consumer
that has to guess it will guess worse.

- **`title`** (required). Names the phase, not the lessons in it.
- **`description`** (optional). One line.
- **`lessons`** (required, ordered, non-empty).

A course too short to have phases is one module holding every lesson — say so explicitly
rather than omitting the level.

### Lessons

- **`title`** (required). Matches the lesson's `h1`.
- **`slug`** (required). The lesson filename without extension, so it stays stable.
- **`html`** (required). Workspace-relative path to the rendered lesson.
- **`estimatedMinutes`** (optional, integer). Reading time, ~200 words/minute.
- **`body`** (required). The lesson prose as markdown. Include the do-steps as an ordered
  list and the callouts as blockquotes — the structure the HTML expresses with classes,
  expressed here with markdown syntax instead. Omit the `h1`; the title carries it.
- **`keyConcepts`** (optional). The named ideas this lesson teaches, as strings. These are
  what a consumer maps onto its own concept model, so name the idea, not the activity:
  `"Progressive overload"`, not `"doing the sets"`.
- **`links`** (optional). Citations from the lesson. `type` is a free string
  (`reference`, `video`, `docs`).
- **`quiz`** (optional). See below.

### Quiz items

One entry per question in the lesson, in the order the lesson asks them.

- **`prompt`** (required). The question text, no leading number.
- **`options`** (required, 2+). Each `{ text, correct }`. **Exactly one `correct: true`.**
- **`explanation`** (optional but strongly wanted). Why the correct answer is correct —
  one or two sentences. The HTML lesson's inline feedback is generic ("Right." /
  "Almost — re-read above."), which teaches nothing on a wrong answer. This field is the
  place to write the real explanation, and a consumer that grades these questions will
  surface it. Write it even though the HTML has nowhere to show it.

## Rules

- **The manifest is generated from the lessons, not the other way round.** Write the
  lessons first, as always. Packing is a separate, later act.
- **Regenerate the whole file.** Never hand-patch one lesson entry — the manifest is
  cheap to rewrite and expensive to have half-stale.
- **Keep slugs stable.** A consumer re-importing a course matches on `slug`; changing one
  reads as a different lesson.
- **Never invent content while packing.** Everything in `course.json` comes from the
  workspace. The one exception is `explanation` on quiz items, which the HTML has no slot
  for — write those from the lesson's own prose, not from outside knowledge.
