#!/usr/bin/env bash
# Everything after the build, in order: olean-based checks, then the export retry and export-based checks.
W=/home/rhcheck/work
bash $W/gold/run/07a-olean-checks.sh
bash $W/gold/run/07b-export-checks.sh
