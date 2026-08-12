# HyperEnv site — https://hyperenv.falcaosl.com
#
# The site is plain HTML and CSS with no build step, so this is a copy into
# nginx and nothing more. Build context is the repository root.
#
#   docker build -f deploy/site/Dockerfile -t hyperenv-site .
#   docker run --rm -p 8080:80 hyperenv-site

FROM nginx:alpine

COPY deploy/site/nginx.conf /etc/nginx/conf.d/default.conf

# _headers is for Netlify / Cloudflare Pages and means nothing to nginx — its
# rules live in nginx.conf instead. Shipping it would publish a file that
# describes headers the server is not actually sending.
COPY site/ /usr/share/nginx/html/
RUN rm -f /usr/share/nginx/html/_headers /usr/share/nginx/html/README.md

EXPOSE 80
