#!/bin/bash

set -o errexit

if [ "$#" -ne 2 ]; then
    echo "Incorrect parameters"
    echo "Usage: build-services.sh <version> <prefix>"
    exit 1
fi

VERSION=$1
PREFIX=$2
SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

pushd "$SCRIPTDIR/reviews"
  # java build the app.
  docker run --rm -u root -v "$(pwd)":/home/gradle/project -w /home/gradle/project gradle:4.8.1 gradle clean build
  pushd reviews-wlpcfg
    docker build --pull -t "${PREFIX}/examples-bookinfo-reviews-v5:${VERSION}" -t "${PREFIX}/examples-bookinfo-reviews-v5:latest" --build-arg service_version=v5 \
	   --build-arg enable_ratings=true --build-arg star_color=yellow .
  popd
popd