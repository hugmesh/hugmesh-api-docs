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
# --base-href IS REQUIRED and its absence is silent. The fe-gateway routes
# `/api-docs/**` here (specs/cluster/apps/20-gateway-fe.yaml:258), so every asset and
# lazy chunk this bundle requests must resolve under /api-docs/. Without the flag Angular
# writes `<base href="/">` and the remote 404s its own chunks the moment it is loaded
# through the gateway -- while continuing to work perfectly when served directly, which
# is what makes this class of bug survive.
#
# NOT the same path the shell MOUNTS it at. The host shell exposes the route as
# /admin/docs (deliberately, so it cannot collide with the gateway prefix -- see the same
# gateway file at :177); the base href is about where the BYTES are fetched from, not
# where the route appears in the URL bar.
RUN npm run build:api-docs -- --base-href=/api-docs/

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/api-docs/browser /usr/share/nginx/html
EXPOSE 80
