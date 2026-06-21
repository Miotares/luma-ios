<!-- BEGIN FOREMAN -->
## Foreman task board

You have access to the Foreman task board for project "luma-ios" via MCP (tool prefix: foreman_*).

At the start of each session:
1. get_project_brain("luma-ios") — loads project memory and structure map
2. list_tasks("luma-ios") — loads the board with your goals and context injected

FIRST-TIME SETUP — do this ONCE, only if the board is still empty (get_project_context("luma-ios") returns no goals/context AND get_project_brain("luma-ios") is empty). That means Foreman was just connected to an existing codebase, so bootstrap it from the repo:
1. Read the codebase: README, package manifest, directory layout, key entry points.
2. set_project_context("luma-ios", goals, context) — goals = what this project is and aims to achieve; context = tech stack, conventions, architecture rules an agent must respect. (Fills only empty fields; it never overwrites the human's edits.)
3. update_project_brain("luma-ios", structure, progress_log) — structure = a pointer map of where things live; progress_log = current state and notable recent decisions.
4. create_task("luma-ios", …) for the obvious next steps, bugs, or TODOs you found in the code.
5. Tell the human you bootstrapped the board from the codebase and ask them to review/refine the Kontext tab.
On later sessions the board is already populated — skip setup.

When you finish a task:
- add_comment(id, "REVIEW: <plain summary for the human + numbered verification steps>")
- move_task(id, "Needs Review")

When unsure what to work on: suggest_next_task("luma-ios")
<!-- END FOREMAN -->
