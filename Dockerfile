# hugmesh-api-docs — builds the api-docs native-federation REMOTE
# (src → dist/api-docs) and serves it via nginx with CORS so the
# hugmesh.net host can fetch its remoteEntry.json cross-origin.
# Deployed to the hugmesh-frontend namespace, fronted by the fe-gateway at
# /admin/docs. Casdoor-admin-role guarded by the host (defense in depth:
# each service's springdoc /v3/api-docs is also ROLE_ADMIN-gated in prod).
# Angular CLI 22 requires Node >= 24.15.
FROM node:24-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build:api-docs

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/api-docs/browser /usr/share/nginx/html
EXPOSE 80
