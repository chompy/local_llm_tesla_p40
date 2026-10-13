#!/usr/bin/env bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
BASE_DIR="$SCRIPT_DIR/.."
LLAMA_PATH="$BASE_DIR/lib/llama_cpp"

if [ -d "$LLAMA_PATH/build" ]; then
	echo "> Delete previous build"
	rm -r "$LLAMA_PATH/build"
fi

if [ -d $LLAMA_PATH ]; then
	echo "> Pulling latest commits"
	cd $LLAMA_PATH
	git pull --rebase origin master
else
	echo "> Cloning llama.cpp"
	mkdir -p $BASE_DIR/lib
	git clone https://github.com/ggml-org/llama.cpp.git $LLAMA_PATH
fi

echo "> Starting build"
cd $LLAMA_PATH
cmake -B build -DGGML_CUDA=ON -DGGML_CUDA_FORCE_MMQ=ON -DGGML_CUDA_FORCE_CUBLAS=ON
cmake --build build --config Release
