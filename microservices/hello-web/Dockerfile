# Static hello-world page served by unprivileged nginx on port 8080.
# stable-alpine tracks the supported nginx release; apk upgrade applies Alpine security fixes
# published since the base image was built, so the Trivy gate sees a patched image.
FROM nginxinc/nginx-unprivileged:stable-alpine
USER root
RUN apk upgrade --no-cache
USER 101
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 8080