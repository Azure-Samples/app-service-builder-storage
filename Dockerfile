FROM node:24-alpine AS build
WORKDIR /app/client
COPY client/package*.json ./
RUN npm ci
COPY client/ ./
RUN npm run build

FROM node:24-alpine
WORKDIR /app/server
COPY server/package*.json ./
RUN npm ci --omit=dev
COPY --from=build /app/client/dist/ /app/client/dist/
COPY server/ ./
ENV PORT=8080
USER node
EXPOSE 8080
CMD ["node", "index.js"]
