ARG VERSION=24.0.1

# Begin download and verification stage
FROM debian:bullseye-slim as download
ARG VERSION

WORKDIR /download

RUN apt-get update -y \
  && apt-get install -y wget git gnupg

# Load Bitcoin Core signer keys
RUN set -ex \
  && for key in \
     152812300785C96444D3334D17565732E08E5E41 \
     0AD83877C1F0CD1EE9BD660AD7CC770B81FD22A8 \
     101598DC823C1B5F9A6624ABA5E0907A0380E6C3 \
     CFB16E21C950F67FA95E558F2EEB9F5CC09526C1 \
     F19F5FF2B0589EC341220045BA03F4DBE0C63FB4 \
     F4FC70F07310028424EFC20A8E4256593F177720 \
     D1DBF2C4B96F2DEBF4C16654410108112E7EA81F \
     287AE4CA1187C68C08B49CB2D11BD4F33F1DB499 \
     9DEAE0DC7063249FB05474681E4AED62986CD25D \
     3EB0DEE6004A13BE5A0CC758BF2978B068054311 \
     9D3CC86A72F8494342EA5FD10A41BDC3F4FAFF1C \
     ED9BDF7AD6A55E232E84524257FF9BDBCC301009 \
     6A8F9C266528E25AEB1D7731C2371D91CB716EA7 \
     28E72909F1717FE9607754F8A7BEB2621678D37D \
     590B7292695AFFA5B672CBB2E13FC145CD3F4304 \
     79D00BAC68B56D422F945A8F8E3A8F3247DBCBBF \
  ; do \
      gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$key" || \
      gpg --batch --keyserver keys.openpgp.org --recv-keys "$key" || \
      gpg --batch --keyserver pgp.mit.edu --recv-keys "$key" || \
      gpg --batch --keyserver keyserver.pgp.com --recv-keys "$key" || \
      gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys "$key" || \
      gpg --batch --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys "$key" ; \
    done

# Download and verify source code
RUN wget https://bitcoincore.org/bin/bitcoin-core-$VERSION/bitcoin-$VERSION.tar.gz \
  && wget https://bitcoincore.org/bin/bitcoin-core-$VERSION/SHA256SUMS \
  && wget https://bitcoincore.org/bin/bitcoin-core-$VERSION/SHA256SUMS.asc

RUN gpg --verify SHA256SUMS.asc SHA256SUMS \
  && grep " bitcoin-$VERSION.tar.gz" SHA256SUMS | sha256sum -c - \
  && tar -xzf bitcoin-$VERSION.tar.gz

# Apply the Ordisrespector patch
WORKDIR /download/bitcoin-$VERSION
COPY Ordisrespector.patch Ordisrespector.patch
RUN git apply Ordisrespector.patch

# Begin build stage
FROM debian:bullseye-slim as build
ARG VERSION

# Install build tools and dependencies
RUN apt-get update -y \
  && apt-get install -y \
      build-essential \
      libtool \
      autotools-dev \
      automake \
      pkg-config \
      bsdmainutils \
      python3 \
      libevent-dev \
      libboost-dev

WORKDIR /bitcoin
COPY --from=download /download/bitcoin-$VERSION /bitcoin

# This is the build step, it takes a while
RUN ./autogen.sh \
  && ./configure \
    --disable-bench \
    --disable-gui-tests \
    --disable-maintainer-mode \
    --disable-man \
    --disable-tests \
    --with-daemon=yes \
    --with-gui=no \
    --with-qrencode=no \
    --with-utils=yes \
  && make

# Remove the debug symbols
RUN strip src/bitcoin-cli \
  && strip src/bitcoin-tx \
  && strip src/bitcoin-util \
  && strip src/bitcoind

# Begin bin stage
FROM debian:bullseye-slim as bin
ARG VERSION

# Run as a non-privileged user
RUN useradd -r bitcoin \
  && apt-get update -y \
  && apt-get install -y libevent-2.1-7 libevent-pthreads-2.1-7 gosu \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENV BITCOIN_DATA=/home/bitcoin/.bitcoin
ENV BITCOIN_BIN=/opt/bitcoin-$VERSION/bin
ENV PATH=$BITCOIN_BIN:$PATH

# Copy the binaries built in this Dockerfile
COPY --from=build /bitcoin/src/bitcoin-cli $BITCOIN_BIN/bitcoin-cli
COPY --from=build /bitcoin/src/bitcoin-tx $BITCOIN_BIN/bitcoin-tx
COPY --from=build /bitcoin/src/bitcoin-util $BITCOIN_BIN/bitcoin-util
COPY --from=build /bitcoin/src/bitcoind $BITCOIN_BIN/bitcoind

COPY docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/home/bitcoin/.bitcoin"]

EXPOSE 8332 8333 18333 18443 18444 38333 38332

ENTRYPOINT ["/entrypoint.sh"]

RUN bitcoind -version | grep "Bitcoin Core version v$VERSION"

CMD ["bitcoind"]
