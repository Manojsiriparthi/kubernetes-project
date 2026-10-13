FROM nginx:1.27-alpine

RUN rm /etc/nginx/conf.d/default.conf \
    && sed -i 's|^[[:space:]]*pid[[:space:]].*;|pid /tmp/nginx.pid;|' /etc/nginx/nginx.conf \
    && sed -i '/^[[:space:]]*user[[:space:]]/d' /etc/nginx/nginx.conf \
    && chown -R nginx:nginx /usr/share/nginx/html /var/cache/nginx /var/run

COPY --chown=nginx:nginx nginx.conf /etc/nginx/conf.d/default.conf
COPY --chown=nginx:nginx index.html styles.css app.js /usr/share/nginx/html/

USER nginx
EXPOSE 8080
