#!/bin/bash
# MESA RStudio entrypoint. VICE runs the container as UID 1000 (rstudio), so
# root-only steps go through sudo; locally it may also run as root.
# supervisord runs nginx (:80) in front of rserver (127.0.0.1:8787).
[ "$(id -u)" = 0 ] && SUDO= || SUDO=sudo

# iRODS env, Data Store dotfiles (.gitconfig/.aws/.ssh), .env files, OSN mounts,
# written into rstudio's home (upstream wrote these into /root)
if [ "$(id -un)" = rstudio ]; then
  (cd ~ && source /usr/local/bin/mesa-init.sh)
else
  sudo -u rstudio -H --preserve-env=IPLANT_USER bash -c 'cd ~ && source /usr/local/bin/mesa-init.sh'
fi

# /etc/nginx is owned by 1000; no sudo here: sudo would strip REDIRECT_URL
gomplate -f /nginx.conf.tmpl -o /etc/nginx/nginx.conf
# nginx on :80 and rserver need root (as in upstream cyverse-vice/rstudio-geospatial)
exec $SUDO supervisord -c /etc/supervisor/supervisord.conf -n
