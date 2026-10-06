# HyperEnv site — https://hyperenv.falcaosl.com
#
# The site is HTML, CSS and one small script with no build step, so this is a
# copy into nginx and nothing more. Build context is the repository root.
#
#   docker build -f site/deploy/Dockerfile -t hyperenv-site .
#   docker run --rm -p 8080:80 hyperenv-site

FROM nginx:alpine

COPY site/deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY site/deploy/security-headers.conf /etc/nginx/snippets/hyperenv-security-headers.conf

# _headers is for Netlify / Cloudflare Pages and means nothing to nginx — its
# rules live in nginx.conf instead. Shipping it would publish a file that
# describes headers this server is not actually sending.
COPY site/ /usr/share/nginx/html/
# site/deploy holds this file and the nginx config: build inputs, never pages.
RUN rm -rf /usr/share/nginx/html/deploy \
 && rm -f /usr/share/nginx/html/_headers /usr/share/nginx/html/README.md \
 && nginx -t

EXPOSE 80
