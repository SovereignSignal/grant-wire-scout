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

# The OAuth credential from `claude setup-token` lives on a Railway VOLUME mounted at
# $HOME/.claude, so it persists and refreshes in place across runs. HOME must be writable.
ENV HOME=/app/home
RUN mkdir -p "$HOME/.claude"

# Overridden per Railway service:
#   scout cron     -> bin/run-all.sh           (cronSchedule "0 4 * * *", volume at /app/home/.claude)
#   heartbeat cron -> python3 lib/heartbeat.py (cronSchedule "0 14 * * *", no volume)
CMD ["bin/run-all.sh"]
