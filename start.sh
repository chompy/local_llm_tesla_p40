#!/usr/bin/env bash

BASE_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

if [ -d "$BASE_DIR/llama_cpp" ]; then
	$BASE_DIR/scripts/build_llama_cpp.sh
fi

$BASE_DIR/scripts/start_llama_swap.sh &
$BASE_DIR/scripts/start_opencode.sh &
