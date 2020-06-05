#!/usr/bin/env sh

docker run --rm -p 1948:1948 -v $(pwd):/slides webpronl/reveal-md:3.4.7

