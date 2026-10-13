#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BASE_DIR="$SCRIPT_DIR/.."
LLAMA_SWAP_PATH="$BASE_DIR/lib/llama_swap"

if [ -d $LLAMA_SWAP_PATH ]; then
	echo "> Delete existing llama-swap"
	rm -r $LLAMA_SWAP_PATH
fi

echo "> Fetching llama-swap release"
if [ -f /tmp/ls.tar.gz ]; then
	rm /tmp/ls.tar.gz
fi
curl -L "https://github.com/mostlygeek/llama-swap/releases/download/v264/llama-swap_264_linux_arm64.tar.gz" -o /tmp/ls.tar.gz

echo "> Extracting"
mkdir -p $LLAMA_SWAP_PATH
cd $LLAMA_SWAP_PATH
tar xvfz /tmp/ls.tar.gz
rm /tmp/ls.tar.gz
