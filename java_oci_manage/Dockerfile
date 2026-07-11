FROM debian:bullseye
LABEL maintainer="Stille <stille@ioiox.com>"

ENV VERSION 9.9.0

RUN apt update && \
    apt install -y wget curl bash util-linux procps && \
    apt clean && \
    apt autoclean

WORKDIR /app

COPY app/sh_client_bot.sh /app/sh_client_bot.sh
RUN chmod +x /app/sh_client_bot.sh

ENTRYPOINT ["/bin/bash", "/app/sh_client_bot.sh"]
