# grant-wire-scout — shared Railway image for the Claude scout cron, the Grok Build
# scout cron, AND the heartbeat cron (same image, different start commands per service).
FROM node:22-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip ca-certificates curl bash \
 && rm -rf /var/lib/apt/lists/*

# Claude Code CLI — the Claude scout runs headless `claude -p`. PINNED: a floating
# Claude CLI can change flag semantics and silently kill the scout, so bump deliberately.
# Opus 5.5 (`claude-opus-5-5`) was added in 2.1.280 (2026-09-22); 2.1.195 cannot select it.
# 2.1.288 is the current release as of 2026-10-03. node:22-slim stays floating so it keeps
# security patches within the 22 line; pin the base image by digest if you need full
# build reproducibility. This pin is Claude-only — the Grok CLI below is not pinned.
RUN npm install -g @anthropic-ai/claude-code@2.1.288

# Grok Build CLI — latest stable at image build. Do not pass a version: xAI rejects
# old builds with HTTP 426 (on 2026-10-01, 1.0.5 was refused; minimum was 1.0.13) and a
# pin fails every wire until the next image. Each Grok wire also runs `grok update`
# before the hunt (bin/ensure-grok-cli.sh). GROK_DISABLE_AUTOUPDATER keeps a background
# check from stalling `grok -p`; the explicit update unsets it. GROK_BIN_DIR puts the
# binary on PATH (/usr/local/bin), not under GROK_HOME — that path is the session volume.
ENV HOME=/app/home \
    GROK_BIN_DIR=/usr/local/bin \
    GROK_DISABLE_AUTOUPDATER=1 \
    GROK_HOME=/app/home/.grok
RUN mkdir -p "$HOME" "$GROK_HOME" \
 && curl -fsSL https://x.ai/cli/install.sh | bash \
 && (grok version || grok --version)

WORKDIR /app
COPY requirements.txt ./
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt
COPY . .
RUN chmod +x bin/*.sh run-producer.sh

# Claude auth = CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`).
# Grok auth  = GROK_AUTH_JSON (contents of ~/.grok/auth.json from `grok login`),
#              hydrated at cron start by lib/hydrate_grok_auth.py. Mount a volume at
#              /app/grok-session and set GROK_HOME there — not /app/home/.grok, which
#              also holds the CLI binary.
RUN mkdir -p "$HOME/.claude"

# Overridden per Railway service:
#   scout cron      -> bin/run-all.sh            (cronSchedule "0 4 * * 0,2,4,6")
#   grok-scout cron -> bin/run-grok-all.sh       (cronSchedule "0 6 * * 1,3,5")
#   heartbeat cron  -> python3 lib/heartbeat.py  (cronSchedule "0 14 * * *")
CMD ["bin/run-all.sh"]
