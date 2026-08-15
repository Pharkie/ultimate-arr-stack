ARG UBUNTU_VERSION=24.04

####################################
# Temporary image for building Duc #
####################################

FROM ubuntu:${UBUNTU_VERSION} AS build

ARG DUC_VERSION=1.4.5

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
        build-essential \
        ca-certificates \
        checkinstall \
        curl \
        libcairo2-dev \
        libncursesw5-dev \
        libpango1.0-dev \
        libtokyocabinet-dev \
        pkg-config \
 && rm -rf /var/lib/apt/lists/*

ADD https://github.com/zevv/duc/releases/download/${DUC_VERSION}/duc-${DUC_VERSION}.tar.gz .

RUN tar xzf duc-${DUC_VERSION}.tar.gz \
 && cd duc-${DUC_VERSION} \
 && ./configure \
 && make -j"$(nproc)" \
 && checkinstall --install=no --default \
 && cp duc_${DUC_VERSION}-*.deb /duc.deb

###############################
# Final image for running Duc #
###############################

FROM ubuntu:${UBUNTU_VERSION}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG BUILD_DATE
ARG VCS_REF
LABEL maintainer="Maximilian Köstler <maximilian@koestler.dev>" \
      org.label-schema.build-date=$BUILD_DATE \
      org.label-schema.vcs-url="https://github.com/MaximilianKoestler/duc-service.git" \
      org.label-schema.vcs-ref=$VCS_REF \
      org.label-schema.schema-version="1.0.0-rc1"

COPY --from=build /duc.deb /

RUN dpkg -i /duc.deb \
 && rm /duc.deb \
 && apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
        cron \
        fcgiwrap \
        libcairo2 \
        libpango-1.0 \
        libpangocairo-1.0-0 \
        libtokyocabinet9 \
        nginx \
 && rm -rf /var/lib/apt/lists/* \
 && rm -rf /var/www/html/* \
 && mkdir -p /database /scan

COPY app/nginx.conf /etc/nginx/nginx.conf
COPY app/ducrc /etc/ducrc

COPY app/duc.cgi /var/www/html/duc.cgi
COPY app/manual_scan.cgi /var/www/html/manual_scan.cgi
COPY app/log.cgi /var/www/html/log.cgi

COPY app/startup.sh /startup.sh
COPY app/scan.sh /scan.sh
COPY app/manual_scan.sh /manual_scan.sh

# Default schedule: everyday at midnight
ENV SCHEDULE 0 0 * * *

EXPOSE 80

STOPSIGNAL SIGTERM

CMD ["/startup.sh"]
