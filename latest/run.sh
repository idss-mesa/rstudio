#!/bin/bash
# MESA RStudio entrypoint (runs as root): per-user setup as rstudio, then
# supervisord runs nginx (:80) in front of rserver (127.0.0.1:8787).

# iRODS env, Data Store dotfiles (.gitconfig/.aws/.ssh), .env files, OSN mounts.
# Upstream wrote these into /root; run them as rstudio so they land in its home.
sudo -u rstudio -H --preserve-env=IPLANT_USER bash -c 'cd ~ && source /usr/local/bin/mesa-init.sh'

gomplate -f /nginx.conf.tmpl -o /etc/nginx/nginx.conf
exec supervisord -c /etc/supervisor/supervisord.conf -n
