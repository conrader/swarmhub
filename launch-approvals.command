#!/bin/zsh -l
cd ~/code/agentapp && exec ~/.local/bin/sb-macjob --agent ermes --label agentapp-approvals --workdir ~/code/agentapp -- sh -c '/opt/homebrew/bin/codex exec --skip-git-repo-check -s workspace-write - < BRIEF-approvals.md'
