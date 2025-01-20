# It's highly recommended to run the docker container with volume /database mounted to external directory
# for save blockchain and wallet data on restart container
# Example for run container from this image:
# docker run --volume $(pwd)/database:/database --read-only --rm --detach -p 9555:9555 --name qbitcoin qbitcoin
# then you can run "docker exec qbitcoin qbitcoin-cli help"
FROM ubuntu:24.04
WORKDIR /database
ENV dbi=sqlite
ENV database=qbitcoin
COPY .cpan /root/.cpan
COPY . /qbitcoin
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -qqy apt-utils && \
    apt-get install -qqy \
        perl-base librole-tiny-perl libjson-xs-perl libdbi-perl libjson-xs-perl libhash-multivalue-perl \
        libtie-ixhash-perl libparams-validate-perl libhttp-message-perl libcryptx-perl \
        libsqlite3-0 libdbd-sqlite3-perl make gcc libgmp-dev && \
    rm -rf /var/lib/apt/lists/* && \
    cpan Encode::Base58::GMP Math::GMPz Crypt::PK::ECC::Schnorr Crypt::PQClean::Sign && \
    rm -rf /root/.cpan && \
    apt-get -qqy remove make gcc libgmp-dev && apt-get -qqy auto-remove

ENV PERL5LIB=/qbitcoin/lib
ENV PATH=${PATH}:/qbitcoin/bin
CMD if mount | grep -q " on /database "; then \
      /qbitcoin/bin/qbitcoin-init --dbi=${dbi} --database=${database} /qbitcoin/db && \
      exec /qbitcoin/bin/qbitcoind --peer=node.qcoin.info --dbi=${dbi} --database=${database} --log=/dev/null --verbose; \
    else echo "Please mount /database as external volume"; \
    fi

EXPOSE 9555
