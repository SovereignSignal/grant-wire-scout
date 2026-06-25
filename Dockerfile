# grant-wire-scout — shared Railway image for BOTH the scout cron and the heartbeat cron
# (same image, different start commands per Railway service).
FROM node:22-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Claude Code CLI — the scout runs headless `claude -p`
RUN npm install -g @anthropic-ai/claude-code

WORKDIR /app
COPY requirements.txt ./
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt
COPY . .
RUN chmod +x bin/*.sh

# Auth is the CLAUDE_CODE_OAUTH_TOKEN env var (from `claude setup-token`) — no volume needed.
# Set HOME to a writable path so the claude CLI can write its config/cache.
ENV HOME=/app/home
RUN mkdir -p "$HOME/.claude"

# Overridden per Railway service:
#   scout cron     -> bin/run-all.sh           (cronSchedule "0 4 * * *")
#   heartbeat cron -> python3 lib/heartbeat.py (cronSchedule "0 14 * * *")
CMD ["bin/run-all.sh"]
