# grant-wire-scout — shared Railway image for the Claude scout cron, the Grok Build
# scout cron, AND the heartbeat cron (same image, different start commands per service).
FROM node:22-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip ca-certificates curl bash \
 && rm -rf /var/lib/apt/lists/*

# Claude Code CLI — the Claude scout runs headless `claude -p`. PINNED (C3): a breaking CLI
# release could change flag semantics and silently kill the scout, so bump deliberately.
# node:22-slim stays floating so it keeps security patches within the 22 line; pin the base
# image by digest if you need full build reproducibility.
RUN npm install -g @anthropic-ai/claude-code@2.1.195

# Grok Build CLI — the parallel grok-scout service runs headless `grok -p`. PINNED the same
# way as Claude. Bump by changing GROK_CLI_VERSION (https://x.ai/cli/stable).
ENV HOME=/app/home \
    GROK_BIN_DIR=/usr/local/bin \
    GROK_DISABLE_AUTOUPDATER=1 \
    GROK_HOME=/app/home/.grok \
    GROK_CLI_VERSION=1.0.5
RUN mkdir -p "$HOME" "$GROK_HOME" \
 && curl -fsSL https://x.ai/cli/install.sh | bash -s "$GROK_CLI_VERSION" \
 && grok --version

WORKDIR /app
COPY requirements.txt ./
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt
COPY . .
RUN chmod +x bin/*.sh run-producer.sh

# Claude auth = CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`).
# Grok auth  = GROK_AUTH_JSON (contents of ~/.grok/auth.json from `grok login`),
#              hydrated at cron start by lib/hydrate_grok_auth.py. Mount a volume at
#              /app/home/.grok so CLI refresh tokens survive between cron ticks.
RUN mkdir -p "$HOME/.claude"

# Overridden per Railway service:
#   scout cron      -> bin/run-all.sh            (cronSchedule "0 4 * * *")
#   grok-scout cron -> bin/run-grok-all.sh       (cronSchedule "0 6 * * *")
#   heartbeat cron  -> python3 lib/heartbeat.py  (cronSchedule "0 14 * * *")
CMD ["bin/run-all.sh"]
