#!/bin/sh
# Run by the nginx image's entrypoint (/docker-entrypoint.d) before nginx
# starts. nginx reads its certificate only at start and on reload, so reload
# it every six hours to pick up a certificate renewed by cert-manager.
(
  while sleep 21600; do
    nginx -s reload
  done
) &
