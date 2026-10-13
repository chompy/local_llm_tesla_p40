#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BASE_DIR="$SCRIPT_DIR/.."
OPENCODE_DIR="$BASE_DIR/lib/opencode"

if [ ! -d $OPENCODE_DIR ]; then
	mkdir -p $OPENCODE_DIR
fi

cd $OPENCODE_DIR
npm install @opencode/cli
