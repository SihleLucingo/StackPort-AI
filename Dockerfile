FROM node:20-alpine AS build
WORKDIR /workspace
COPY package.json ./
COPY shared/package.json shared/package.json
COPY shared/tsconfig.json shared/tsconfig.json
COPY shared/src shared/src
COPY backend/package.json backend/package.json
COPY backend/tsconfig.json backend/tsconfig.json
COPY backend/src backend/src
COPY extension/package.json extension/package.json
RUN npm install --workspaces --include-workspace-root
RUN npm run build --workspace @stackport/shared && npm run build --workspace @stackport/backend

FROM node:20-alpine AS production
ENV NODE_ENV=production
ENV PORT=8080
WORKDIR /app
COPY package.json ./
COPY shared/package.json shared/package.json
COPY backend/package.json backend/package.json
COPY extension/package.json extension/package.json
RUN npm install --omit=dev --workspaces --include-workspace-root
COPY --from=build /workspace/shared/dist shared/dist
COPY --from=build /workspace/backend/dist backend/dist
RUN addgroup -S app && adduser -S app -G app && chown -R app:app /app
USER app
EXPOSE 8080
CMD ["node", "backend/dist/server.js"]
