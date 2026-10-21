# Minimal, dependency-free image so the CI build is fast and reproducible.
FROM node:22-alpine

WORKDIR /app

ENV NODE_ENV=production \
    PORT=8080

COPY package.json ./
COPY server.js ./

EXPOSE 8080

USER node

CMD ["node", "server.js"]
