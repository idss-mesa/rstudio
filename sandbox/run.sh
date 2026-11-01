#!/bin/bash
# MESA RStudio AI Sandbox entrypoint: no sudo, no root. supervisord, nginx (:8080)
# and rserver (127.0.0.1:8787) all run as UID 1000 (rstudio); everything that
# the stock image kept under /var/run or /var/log goes to /tmp.
set -u
(cd ~ && source /usr/local/bin/mesa-init.sh)

mkdir -p /tmp/rstudio-server/db /tmp/nginx
printf 'provider=sqlite\ndirectory=/tmp/rstudio-server/db\n' > /tmp/rstudio-server/database.conf
chmod 600 /tmp/rstudio-server/database.conf

# /etc/nginx is owned by 1000; REDIRECT_URL comes from VICE (or the image default)
gomplate -f /nginx.conf.tmpl -o /etc/nginx/nginx.conf
exec supervisord -c /etc/supervisor/supervisord.conf -n
