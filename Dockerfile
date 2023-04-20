FROM alpine

RUN apk add --no-cache curl jq

RUN curl -L https://fly.io/install.sh > install.sh
RUN FLYCTL_INSTALL=/usr/local install.sh v0.0.521

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
