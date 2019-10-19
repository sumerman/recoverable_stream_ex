#!/bin/sh

fswatch -l 0.2 -o ./lib ./test | mix test --stale --color --listen-on-stdin
