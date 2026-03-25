# Global Claude Code Configuration
# Lives at ~/.claude/CLAUDE.md on the VM
# Applies to all projects. Override per-project with CLAUDE.md at repo root.

## Autonomous Workflow

When you finish a task:
1. Commit the work with a clear message referencing the task
2. Check TASKS.md in this repo for the next unblocked task in "Ready"
3. If a ready task exists, move it to "In Progress" and begin planning it
4. Present the plan clearly, then proceed unless the plan requires a decision
5. Only stop and wait if you genuinely need input that cannot be inferred

When picking up a GitHub issue or TASKS.md item:
1. Read it thoroughly
2. Produce a written plan — what files will change, what the approach is, any risks
3. If the plan is straightforward, proceed
4. If the plan involves irreversible changes (schema migrations, deletions), stop and confirm

## Permissions

- You have permission to read, write, and delete files in any project
- You have permission to run npm, npx, python, pip, git commands
- You have permission to run dev servers and build tools
- You have permission to install packages
- Do not ask for confirmation on routine file operations
- Never set user.email or user.name in local git config — identity is managed globally

## Commit Style

- Use conventional commits: feat:, fix:, chore:, docs:, refactor:
- Reference task or issue numbers where applicable
- Keep messages concise and descriptive
