#!/bin/sh
# Fires (via the UserPromptExpansion hook in .claude/settings.json) when a
# brainstorming / planning superpowers skill is invoked. Injects a reminder that
# the kata-first gate overrides the skill's own checklist. stdout is added to the
# model's context.
cat <<'EOF'
KATA-FIRST GATE (overrides the skill flow you are about to run):
Before writing any spec, plan, or code, add these to your TodoWrite now and do them in order.
Scope every kata command to this repo's project: --project ingestr.
- [ ] Locate or create the kata EPIC for this topic (search first; --label epic).
- [ ] Create a `design` child under the epic and CLAIM it BEFORE writing the spec.
- [ ] At plan finalization: create a `plan` parent under the epic + one child per task
      (idempotency keys; --blocked-by for ordering).
- [ ] Claim each task on start; close with evidence (--commit) when verified.
The skill's own checklist NOT mentioning kata does not exempt you from this.
See CLAUDE.md "Issue Tracking with kata" for the full workflow.
EOF
