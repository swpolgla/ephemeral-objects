# syntax=docker/dockerfile:1
FROM swift:6.3.3-noble AS builder

WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --static-swift-stdlib --jobs 1

FROM swift:6.3.3-noble-slim AS runtime

RUN apt-get update \
    && apt-get install --no-install-recommends -y ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 ephemeral \
    && useradd --uid 10001 --gid ephemeral --home-dir /app --shell /usr/sbin/nologin ephemeral

WORKDIR /app
COPY --from=builder --chown=ephemeral:ephemeral /build/.build/release/ephemeral-objects /app/ephemeral-objects
COPY --chown=ephemeral:ephemeral Sources/ephemeral-objects/mgmt-ui /app/Sources/ephemeral-objects/mgmt-ui

RUN mkdir -p /app/config /var/lib/ephemeral-objects /var/log/ephemeral-objects \
    && chown -R ephemeral:ephemeral /app /var/lib/ephemeral-objects /var/log/ephemeral-objects

USER ephemeral:ephemeral
EXPOSE 8080
ENTRYPOINT ["/app/ephemeral-objects"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "8080"]
