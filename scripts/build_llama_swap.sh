#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BASE_DIR="$SCRIPT_DIR/.."
LLAMA_SWAP_PATH="$BASE_DIR/lib/llama_swap"

if [ -d $LLAMA_SWAP_PATH ]; then
	echo "> Delete existing llama-swap"
	rm -r $LLAMA_SWAP_PATH
fi

echo "> Cloning llama-swap"
git clone https://github.com/mostlygeek/llama-swap.git $LLAMA_SWAP_PATH

echo "> Building"
cd $LLAMA_SWAP_PATH
go build
