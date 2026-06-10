FROM oven/bun:1.2.8 AS deps

WORKDIR /app

COPY package.json bun.lock ./

COPY packages/analytics/package.json ./packages/analytics/
COPY packages/auth/package.json ./packages/auth/
COPY packages/billing/package.json ./packages/billing/
COPY packages/company/package.json ./packages/company/
COPY packages/db/package.json ./packages/db/
COPY packages/email/package.json ./packages/email/
COPY packages/integration-platform/package.json ./packages/integration-platform/
COPY packages/integrations/package.json ./packages/integrations/
COPY packages/kv/package.json ./packages/kv/
COPY packages/tsconfig/package.json ./packages/tsconfig/
COPY packages/ui/package.json ./packages/ui/
COPY packages/utils/package.json ./packages/utils/

COPY apps/app/package.json ./apps/app/
COPY apps/portal/package.json ./apps/portal/
COPY apps/api/package.json ./apps/api/
COPY apps/framework-editor/package.json ./apps/framework-editor/

RUN PRISMA_SKIP_POSTINSTALL_GENERATE=true bun install --ignore-scripts

FROM node:22 AS app-builder

WORKDIR /app

COPY --from=oven/bun:1.2.8 /usr/local/bin/bun /usr/local/bin/bun
RUN ln -sf /usr/local/bin/bun /usr/local/bin/bunx

COPY packages ./packages
COPY --from=deps /app/node_modules ./node_modules

RUN cd packages/analytics && bun run build
RUN cd packages/auth && bun run build
RUN cd packages/billing && bun run build
RUN cd packages/email && bun run build
RUN cd packages/integration-platform && bun run build
RUN cd packages/kv && bun run build
RUN cd packages/ui && bun run build

RUN cd packages/db && \
    node scripts/generate-prisma-client-js.js && \
    node scripts/build-dist-schema.js && \
    mkdir -p dist && \
    printf 'export * from "@prisma/client";\n' > dist/index.js

RUN cd packages/company && bun run build

COPY apps/app ./apps/app

ARG NEXT_PUBLIC_BETTER_AUTH_URL
ARG NEXT_PUBLIC_PORTAL_URL
ARG NEXT_PUBLIC_POSTHOG_KEY
ARG NEXT_PUBLIC_POSTHOG_HOST
ARG NEXT_PUBLIC_IS_DUB_ENABLED
ARG NEXT_PUBLIC_API_URL
ENV NEXT_PUBLIC_BETTER_AUTH_URL=$NEXT_PUBLIC_BETTER_AUTH_URL \
    NEXT_PUBLIC_PORTAL_URL=$NEXT_PUBLIC_PORTAL_URL \
    NEXT_PUBLIC_POSTHOG_KEY=$NEXT_PUBLIC_POSTHOG_KEY \
    NEXT_PUBLIC_POSTHOG_HOST=$NEXT_PUBLIC_POSTHOG_HOST \
    NEXT_PUBLIC_IS_DUB_ENABLED=$NEXT_PUBLIC_IS_DUB_ENABLED \
    NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL \
    NEXT_TELEMETRY_DISABLED=1 NODE_ENV=production \
    NEXT_OUTPUT_STANDALONE=true \
    NODE_OPTIONS=--max_old_space_size=4096 \
    SKIP_TYPE_CHECK=1 \
    SKIP_ENV_VALIDATION=1 \
    CI=1

RUN cd apps/app && \
    node -e "const fs=require('fs');let c=fs.readFileSync('next.config.ts','utf8');c=c.replace(/ignoreBuildErrors:[^,]+,/,'ignoreBuildErrors: true,');fs.writeFileSync('next.config.ts',c);" && \
    bunx prisma generate --schema=prisma/schema && \
    node ../../packages/db/scripts/fix-generated-extensions.js src/generated/prisma && \
    node /app/node_modules/next/dist/bin/next build

FROM node:22-alpine

WORKDIR /app

COPY --from=app-builder /app/apps/app/.next/standalone ./
COPY --from=app-builder /app/apps/app/.next/static ./apps/app/.next/static
COPY --from=app-builder /app/apps/app/public ./apps/app/public

EXPOSE 3000
CMD ["node", "apps/app/server.js"]
