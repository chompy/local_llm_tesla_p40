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
# FORCE_MMQ selects the DP4A quantized-GEMM kernels, the fast path on Pascal (sm_61).
# Do NOT also set GGML_CUDA_FORCE_CUBLAS: it takes precedence in code and silently
# disables MMQ, falling back to slower cuBLAS fp32 GEMMs.
cmake -B build -DGGML_CUDA=ON -DGGML_CUDA_FORCE_MMQ=ON
cmake --build build --config Release --parallel $(nproc)
