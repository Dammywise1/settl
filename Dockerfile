# ─────────────────────────────────────────────
# Stage 1 — Install dependencies
# ─────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

# Copy package files first (better layer caching)
COPY backend/package.json backend/package-lock.json* ./backend/

# Install production dependencies only
RUN cd backend && npm install --omit=dev --no-audit --no-fund

# ─────────────────────────────────────────────
# Stage 2 — Production runner
# ─────────────────────────────────────────────
FROM node:20-alpine AS runner

# Security: run as non-root user
RUN addgroup -g 1001 -S settl && \
    adduser  -u 1001 -S settl -G settl

WORKDIR /app

# Copy installed node_modules from builder
COPY --from=builder /app/backend/node_modules ./backend/node_modules

# Copy application source
COPY backend/  ./backend/
COPY frontend/ ./frontend/

# Copy keypair if it exists (Railway uses env var instead — see below)
# COPY backend/keypair.json ./backend/keypair.json

# Set ownership
RUN chown -R settl:settl /app

USER settl

# Railway sets PORT automatically
ENV NODE_ENV=production
ENV PORT=3000

EXPOSE 3000

# Health check — Railway uses this to know the app is ready
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/api/health || exit 1

# Start the server
CMD ["node", "backend/src/server.js"]
