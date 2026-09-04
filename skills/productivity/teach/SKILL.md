---
name: teach
description: Teach the user a new skill or concept, within this workspace.
disable-model-invocation: true
argument-hint: "What would you like to learn about?"
---

The user has asked you to teach them something. This is a stateful request - they intend to learn the topic over multiple sessions.

## Teaching Workspace

Treat the current directory as a teaching workspace. The state of their learning is captured in this directory in several files:

- `MISSION.md`: A document capturing the _reason_ the user is interested in the topic. This should be used to ground all teaching. Use the format in [MISSION-FORMAT.md](./MISSION-FORMAT.md).
- `./reference/*.html`: A directory of reference materials. These are the compressed learnings from the lessons - cheat sheets, reference algorithms, syntax, yoga poses, glossaries. They are the raw units of learning. They should be beautiful documents which print out well, and are designed for quick reference.
- `RESOURCES.md`: A list of resources which can be explored to ground your teaching in contextual knowledge, or to acquire knowledge and wisdom. Use the format in [RESOURCES-FORMAT.md](./RESOURCES-FORMAT.md).
- `./learning-records/*.md`: A directory of learning records, which capture what the user has learned. These are loosely equivalent to architectural decision records in software development - they capture non-obvious lessons and key insights that may need to be revised later, or drive future sessions. These should be used to calculate the zone of proximal development. They are titled `0001-<dash-case-name>.md`, where the number increments each time. Use the format in [LEARNING-RECORD-FORMAT.md](./LEARNING-RECORD-FORMAT.md).
- `./lessons/*.html`: A directory of lessons. A **lesson** is a single, self-contained HTML output that teaches one tightly-scoped thing tied to the mission. This is the primary unit of teaching in this workspace.
- `./assets/*`: Reusable **components** shared across lessons. See [Assets](#assets).
- `NOTES.md`: A scratchpad for you to jot down user preferences, or working notes.
- `course.json`: The machine-readable manifest of the whole course. Write it at the workspace root and keep it current — see [Keep `course.json` current](#keep-coursejson-current). Use the format in [LESSON-PACK-FORMAT.md](./LESSON-PACK-FORMAT.md).

## Philosophy

To learn at a deep level, the user needs three things:

- **Knowledge**, captured from high-quality, high-trust resources
- **Skills**, acquired through highly-relevant interactive lessons devised by you, based on the knowledge
- **Wisdom**, which comes from interacting with other learners and practitioners

Before the `RESOURCES.md` is well-populated, your focus should be to find high-quality resources which will help the user acquire knowledge. Never trust your parametric knowledge.

Some topics may require more skills than knowledge. Learning more about theoretical physics might be more knowledge-based. For yoga, more skills-based.

### Fluency vs Storage Strength

You should be careful to split between two types of learning:

- **Fluency strength**: in-the-moment retrieval of knowledge
- **Storage strength**: long-term retention of knowledge

Fluency can give the user an illusory sense of mastery, but storage strength is the real goal. Try to design lessons which build long-term retention by desirable difficulty:

- Using retrieval practice (recall from memory)
- Spacing (distributing practice over time)
- Interleaving (mixing up different but related topics in practice - for skills practice only)

## Lessons

A lesson is the main thing you produce — the unit in which knowledge and skills reach the user. Each lesson is one self-contained HTML file, saved to `./lessons/` and titled `0001-<dash-case-name>.html` where the number increments each time.

A lesson should be **beautiful** — clean, readable typography and layout — since the user will return to these later to review. Think Tufte.

The lesson should be short, and completable very quickly. Learners' working memory is very small, and we need to stay within it. But each lesson should give the user a single tangible win that they can build on. It should be directly tied to the mission, and should be in the user's zone of proximal development.

If possible, open the lesson file for the user by running a CLI command.

Each lesson should link via HTML anchors to other lessons and reference documents.

Each lesson should recommend a primary source for the user to read or watch. This should be the most high-quality, high-trust resource you found on the topic.

Each lesson should contain a reminder to ask followup questions to the agent. The agent is their teacher, and can assist with anything that's unclear.

## Assets

Lessons are built from reusable **components**, stored in `./assets/`: stylesheets, quiz widgets, simulators, diagram helpers — anything a second lesson could reuse.

Reuse is the default, not the exception. Before authoring a lesson, read `./assets/` and build from the components already there. When a lesson needs something new and reusable, write it as a component in `./assets/` and link to it — never inline code a future lesson would duplicate.

A shared stylesheet is the first component every workspace earns: every lesson links it, so the lessons look like one consistent course rather than a pile of one-offs. As the workspace grows, so should the component library.

## The Mission

Every lesson should be tied into the mission - the reason that the user is interested in learning about the topic.

If the user is unclear about the mission, or the `MISSION.md` is not populated, your first job should be to question the user on why they want to learn this.

Failing to understand the mission will mean knowledge acquisition is not grounded in real-world goals. Lessons will feel too abstract. You will have no way of judging what the user should do next.

Missions may change as the user develops more skills and knowledge. This is normal - make sure to update the `MISSION.md` and add a learning record to capture the change. Confirm with the user before changing the mission.

## Zone Of Proximal Development

Each lesson, the user should always feel as if they are being challenged 'just enough'.

The user may specify an exact thing they want to learn. If they don't, figure out their zone of proximal development by:

- Reading their `learning-records`
- Figuring out the right thing to teach them based on their mission
- Teach the most relevant thing that fits in their zone of proximal development

## Knowledge

Lessons should be designed around a skill the user is going to learn. The knowledge in the lesson should be only what's required to acquire that skill. You teach the knowledge first, then get the user to practice the skills via an interactive feedback loop.

Knowledge should first be gathered from trusted resources. Use `RESOURCES.md` to keep track of them. Lessons should be littered with citations - links to external resources to back up any claim made. This increases the trustworthiness of the lesson.

For acquiring knowledge, difficulty is the enemy. It eats working memory you need for understanding.

## Skills

If knowledge is all about acquisition, skills are about durability and flexibility. Make the knowledge stick.

For skill acquisition, difficulty is the tool. Effortful retrieval is what builds storage strength. Skills should be taught through interactive lessons. There are several tools at your disposal:

- Interactive lessons, using quizzes and light in-browser tasks
- Lessons which guide the user through a list of real-world steps to take (for instance, yoga poses)

Each of these should be based on a **feedback loop**, where the user receives feedback on their performance. This feedback loop should be as tight as possible, giving feedback immediately - and ideally automatically.

For quizzes, each answer should be exactly the same number of words (and characters, if possible). Don't give the user any clues about the answer through formatting.

## Acquiring Wisdom

Wisdom comes from true real-world interaction - testing your skills outside the learning environment.

When the user asks a question that appears to require wisdom, your default posture should be to attempt to answer - but to ultimately delegate to a **community**.

A community is a place (online or offline) where the user can test their skills in the real world. This might be a forum, a subreddit, a real-world class (budget permitting) or a local interest group.

You should attempt to find high-reputation communities the user can join. If the user expresses a preference that they don't want to join a community, respect it.

## Reference Documents

While creating lessons, you should also create reference documents. Lessons can reference these documents - they are useful for tracking raw units of knowledge useful across lessons.

Lessons will rarely be revisited later - reference documents will be. They should be the compressed essence of the lesson, in a format designed for quick reference.

Some learning topics lend themselves to reference:

- Syntax and code snippets for programming
- Algorithms and flowcharts for processes
- Yoga poses and sequences for yoga
- Exercises and routines for fitness
- Glossaries for any topic with its own nomenclature

Glossaries, in particular, are an essential reference. Once one is created, it should be adhered to in every lesson.

## Packing the course for another system

The HTML lessons are written for a human with a browser. They have no declared structure — the section headings, do-steps, callouts and quiz blocks are how one generation run happened to write them, not a contract. Any other system that scrapes those class names breaks silently the first time a lesson is written differently.

So the workspace carries its own machine-readable view. Never tell a consumer to parse the HTML — write `course.json` per [LESSON-PACK-FORMAT.md](./LESSON-PACK-FORMAT.md): the lessons grouped into modules you choose, each body as markdown, each quiz as data, the mission verbatim.

### Keep `course.json` current

Write it as soon as the workspace has its first lesson, and rewrite it in the same turn as any change to the course's content — a lesson added, retitled, renumbered, rewritten, or deleted; a quiz reworded; the mission revised. It is a derived file, so a stale one is worse than a missing one: an import silently ships last week's course, and nothing about the folder looks wrong.

Do not wait to be asked, and do not wait for a packing request. Deciding at packing time is what produced the earlier failure mode — a finished, zipped, shared course with no manifest in it, discovered only when someone tried to import it and had to come back for a second export.

Two things `course.json` holds that no lesson file can, and that are worth the effort every time you rewrite it:

- **Module grouping.** The lesson numbering carries order but not the arc. You taught the course; you know where one phase ends. Emit that judgment rather than leaving a consumer to infer it.
- **Quiz explanations.** The inline HTML feedback is generic by necessity — there is nowhere in a self-contained lesson to put a per-option explanation. `course.json` has a slot for it. Fill it from the lesson's own prose.

## Distributing to a human

A learner never opens `course.json` and does not care that it is there. They have a phone or laptop, a browser, and an email attachment. When the user says "send it to someone," "zip it up," "share with my team," or "I want my mom to take this," the deliverable is a **distributable folder**, not a manifest.

Treat the distributable as a separate artifact from the workspace. Do not let it leak into teaching state. The layout the workspace settles into:

```
<workspace>/
├── MISSION.md                 # teaching state — never distributed
├── NOTES.md                   # teaching state — never distributed
├── RESOURCES.md               # teaching state — never distributed
├── learning-records/          # teaching state — never distributed
├── lessons/                   # source
├── reference/
└── assets/
    └── course.css             # source stylesheet
```

And at the same level, after packing:

```
<workspace>/
├── … (workspace above) …
└── <slug>/                    # distributable — what the learner receives
    ├── README.md              # what's in here, how to host it
    ├── START-HERE.html        # landing page with links to every lesson
    ├── course.css             # copy of the source stylesheet at root
    ├── lessons/
    │   ├── course.css         # sibling copy — see Self-containment below
    │   └── 0001-…0008-…html
    └── reference/
        └── glossary.html
```

### Choosing the slug

The distributable folder name is the **course name in dash-case**, and it is what the learner sees when they unzip. Pick a name that reads like a course title, not a filename: `todoist-for-real-life`, `intro-to-supabase-auth`, `leadership-foundations`. If the user gave you a course title, use it verbatim; otherwise ask before picking — the user has strong opinions about naming, and a wrong name is annoying to rename later (every reference inside the lessons, every zip, every Drive share).

The slug also names the zip (`<slug>.zip`) and is the title of `START-HERE.html`. One name, used three places.

### What gets dropped on the way out

`MISSION.md`, `NOTES.md`, `RESOURCES.md`, and `learning-records/` are **teaching notes for you, not for the learner**. They explain why you built it this way, what to teach next, what to ignore. None of that is useful to someone learning Todoist for the first time. Excluding them keeps the handoff clean and keeps your private teaching state private.

### Self-containment

A learner will not respect the folder structure. They will email a single lesson to a friend, drag it onto a USB stick, or open it on a phone that mangles paths. Each HTML file in `lessons/` must therefore work **as if it were alone** — its `<link rel="stylesheet">` must point at a sibling `course.css`, not at `../assets/course.css` two levels up. This means every lesson ships with its own copy of the stylesheet.

The `reference/glossary.html` is allowed to keep a `../course.css` reference (it lives one level under the package root) — but verify the path resolves in the distributed folder, not just the workspace.

**Pitfall:** if you copy `course.css` next to each lesson via a loop, do not let the destination filename inherit from the source. The naive `shutil.copy(src, dest)` inside `for fn in lessons:` produces `0001-sign-up-and-meet-your-inbox.css`, `0002-projects-personal-and-shared.css`, etc. — the lessons still link to `course.css`, which doesn't exist, and every lesson renders unstyled. Always copy with an explicit destination name: `shutil.copy(src, os.path.join(lessons_dir, "course.css"))`.

### Build procedure

Run from the workspace root. Six steps, fully scripted:

1. Confirm the slug with the user (or pick it from the course title).
2. Create `<slug>/` as a sibling of the source `lessons/` and `reference/`.
3. Copy `lessons/*.html` and `reference/*.html` into it, preserving subfolders.
4. For each lesson HTML, rewrite `<link rel="stylesheet" href="../assets/course.css">` to `<link rel="stylesheet" href="course.css">`. For glossary, rewrite `href="assets/course.css"` to `href="../course.css"` (it sits one level under) and `href="lessons/..."` to `href="../lessons/..."`.
5. Copy `assets/course.css` to two places: `<slug>/course.css` (root) and `<slug>/lessons/course.css` (sibling of every lesson). Drop an empty `assets/` if the source had one and nothing else.
6. **Verify every relative `href` resolves on disk before declaring done.** See Verification below.

Then author:

- **`START-HERE.html`** at `<slug>/` root — a one-page index with the course title, a short "how to take this" list, a table linking every lesson by title, a link to the glossary, and a callout that homework must be done on the learner's real account. Style it with the sibling `course.css`.
- **`README.md`** at `<slug>/` root — for the person handing the course off. Lists what is in the folder, how the learner opens it, and how to host it (Netlify Drop, GitHub Pages, `vercel deploy`). The learner doesn't read this; the distributor does.

### Verification

A broken stylesheet path is **silent** — the lesson renders as raw browser-default HTML and the learner assumes the course is ugly by design. Always run a link check before zipping.

A reference implementation lives at [`scripts/verify-distributable-links.py`](./scripts/verify-distributable-links.py). The check itself is short:

1. Walk the distributable folder.
2. For every `*.html`, extract every `href="..."` value that is not `http://`, `https://`, `#`, or `mailto:`.
3. Resolve each href relative to the file that contains it (`os.path.normpath` join).
4. Confirm the resolved path exists on disk. If any do not, fix and re-run.

Five seconds of work, catches the misnamed-sibling-CSS pitfall and the broken-glossary-path bug every time. Do not skip this step.

### Zip

`cd` to the parent of the `<slug>/` folder — that is, the workspace root. `zip -r <slug>.zip <slug> -x "*.DS_Store"`. Confirm the resulting zip's **top-level entry is the slug folder**, not the contents scattered at the archive root (`zip -sf <slug>.zip | head` shows this). The learner unzips, opens `<slug>/START-HERE.html` — done.

If you zipped from inside `<slug>/` by accident, the archive root will contain `START-HERE.html` and `lessons/` flat — the learner unzips into a mess. Rebuild from the parent.

### `course.json` ships with the folder

Include `course.json` in the distributable folder and the zip, alongside the human-facing artifacts. It costs a learner nothing — they never open it — and it is what makes the folder importable rather than merely readable.

## `NOTES.md`

The user will sometimes express preferences of how they want to be taught, or things you should keep in mind. This is the place to record those preferences, so you can refer back to them when designing lessons or working with the user.
