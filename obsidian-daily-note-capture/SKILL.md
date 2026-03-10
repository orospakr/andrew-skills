---
name: obsidian-daily-note-capture
description: Add user-provided notes, insights, or task summaries to today's Obsidian daily note in ~/Obsidian/Andrew. Use when the user says things like "make a note of this", "add this to my daily note", "log this insight", or asks to capture current work in the daily note.
---

# Obsidian Daily Note Capture

Use this skill when the user wants content written into today's daily note.

## Workflow

1. Resolve today's daily note path first by running:
   `/home/andrew/.codex/skills/obsidian-daily-note-finder/scripts/find_daily_note.sh`
2. Open and read the current daily note before editing.
3. Choose placement with discretion:
   - Preferred: if there is a clearly relevant existing section, update within that section.
   - Otherwise: append a new block at the end of the file and separate it from prior content with `---`.
4. Preserve user intent and wording. If the user asked for a summary, summarize first, then write the summarized text.
5. Never prepend content to the top of the daily note unless the user explicitly asks.
6. If today's daily note is missing, report the expected absolute path and ask whether to create it.

## Section Selection Heuristic

Treat a section as clearly relevant when at least one of these is true:
- The section heading explicitly matches the user's intent (for example "Tasks", "Notes", "Insights", "Wins", "Blockers", "Follow-up").
- The existing items in that section share the same type as the new content (checkbox tasks vs prose notes).
- The user references a section by name.

If relevance is ambiguous, do not guess. Append to the end with `---`.

## Editing Rules

- Use direct file reads and edits via available tools; do not rely on a blind append script.
- Keep formatting consistent with surrounding content (bullets, checkboxes, paragraph style).
- Do not reorder or rewrite unrelated existing notes.
