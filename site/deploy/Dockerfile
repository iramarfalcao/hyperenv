# HyperEnv site — https://hyperenv.falcaosl.com
#
# The site is HTML, CSS and one small script with no build step, so this is a
# copy into nginx and nothing more. Build context is the repository root.
#
#   docker build -f site/deploy/Dockerfile -t hyperenv-site .
#   docker run --rm -p 8080:80 hyperenv-site

# build.txt: one hash over every file this image serves, so a deploy can be
# recognised from outside. Cloudflare rewrites HTML on the way out (email
# obfuscation), so comparing pages with the repository never matches; a plain
# text stamp is passed through untouched. .github/workflows/site-purge.yml
# computes the same hash from the checkout — keep the two recipes identical.
FROM alpine:3 AS stamp
COPY site/ /s/
RUN cd /s && rm -rf deploy _headers README.md \
 && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1 > /build.txt

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

COPY --from=stamp /build.txt /usr/share/nginx/html/build.txt

EXPOSE 80
