# syntax=docker/dockerfile:1

FROM nginx:1.27-alpine

# Remove the default nginx config
RUN rm /etc/nginx/conf.d/default.conf

# Copy our site content and config template
COPY index.html /usr/share/nginx/html/index.html
COPY nginx.conf  /etc/nginx/templates/default.conf.template

# nginx official image automatically runs envsubst on *.template files
# using variables listed in NGINX_ENVSUBST_TEMPLATE_DIR and NGINX_ENVSUBST_OUTPUT_DIR
ENV BACKEND_HOST=localhost

EXPOSE 80

# Default nginx CMD is fine — it reads from /etc/nginx/templates/ automatically
