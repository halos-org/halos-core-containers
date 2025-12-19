# HaLOS mDNS Publisher
# Advertises *.halos.local subdomains via Avahi/mDNS
FROM alpine:3.21

RUN apk add --no-cache \
    bash \
    docker-cli \
    avahi-tools \
    jq

COPY assets/publish-subdomains.sh /usr/local/bin/publish-subdomains.sh
RUN chmod +x /usr/local/bin/publish-subdomains.sh

ENTRYPOINT ["/usr/local/bin/publish-subdomains.sh"]
