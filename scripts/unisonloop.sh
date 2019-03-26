#!/usr/bin/env bash

until (stack build && \
       stack exec unison "$1")
do
  echo "Well that didn't work."
  echo Press any key to re-launch.
  read -n 1
done
