# One TypeScript file, run straight through node's type stripping: no tsc, no build output,
# no dist/ to drift from src/. The image therefore has no runtime dependencies at all —
# `npm ci --omit=dev` installs nothing, and exists only to fail loudly if that ever changes.
# Pinned to an immutable digest, not a moving tag (ruling R28). `node:22-alpine` moves under
# you on every patch release, which is not something a devnet claiming byte-identical boots can
# rest on. The readable tag rides along so the version is visible; the digest is what resolves.
FROM node:22.23.3-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src
USER node
EXPOSE 8545
CMD ["node", "--disable-warning=ExperimentalWarning", "--experimental-strip-types", "src/proxy.ts"]
