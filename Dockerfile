FROM us-central1-docker.pkg.dev/bespokelabs/nebula-devops-registry/nebula-devops:1.0.0

ENV DISPLAY_NUM=1
ENV COMPUTER_HEIGHT_PX=768
ENV COMPUTER_WIDTH_PX=1024

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    postgresql-client \
    python3 \
    && rm -rf /var/lib/apt/lists/*

COPY setup.sh solution.sh /
RUN chmod +x /setup.sh /solution.sh

CMD ["/setup.sh"]