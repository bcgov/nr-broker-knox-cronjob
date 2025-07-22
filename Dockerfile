FROM ${REPO_LOCATION}alpine:3.22.1

### --------------------------------- Install s5cmd
# Install curl, download and extract s5cmd binary
RUN apk add --no-cache curl bash jq && \
    curl -L https://github.com/peak/s5cmd/releases/download/v2.3.0/s5cmd_2.3.0_Linux-64bit.tar.gz -o /tmp/s5cmd.tar.gz && \
    tar -xzf /tmp/s5cmd.tar.gz -C /usr/local/bin s5cmd && \
    chmod +x /usr/local/bin/s5cmd && \
    rm /tmp/s5cmd.tar.gz

# Verify installation of s5cmd and sha256sum
RUN s5cmd version \
    sha256sum /usr/local/bin/s5cmd

RUN mkdir /app
WORKDIR /app

COPY ./src/app /app
COPY --chmod=666 ./src/ENV /tmp/ENV

ENV GITHUB_ENV=/tmp/ENV
ENV GITHUB_OUTPUT=/tmp/OUT

VOLUME [ "/backup" ]

ENTRYPOINT [ "./mask-runner.sh", "./backup-cron.sh" ]
