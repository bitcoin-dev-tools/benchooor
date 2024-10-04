#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ] || [ -z "$6" ]; then
  echo "Usage: $0 /path/to/storage base_filename runs stopatheight dbcache commit_list"
  exit 1
fi

START_DATE=$(date +%Y%m%d%H%M%S)

export STORAGE_PATH="$1"
export BASE_NAME="$2"
export RUNS="$3"
export STOP_AT_HEIGHT="$4"
export DBCACHE="$5"
export COMMIT_LIST="$6"

export DATA_DIR="$STORAGE_PATH/BitcoinData"
export LOG_FILE="$STORAGE_PATH/${BASE_NAME}_${START_DATE}.txt"
export JSON_FILE="$STORAGE_PATH/${BASE_NAME}_${START_DATE}.json"

setup_function() {
  pkill -f 'bitcoind|vmstat'

  git checkout "$COMMIT" || { echo "Failed to checkout commit $COMMIT" >> "$LOG_FILE"; exit 1; }
  COMMIT_MSG=$(git log --format=%B -n 1)

  {
    echo "Starting benchmarking for commit: $COMMIT"
    echo "Commit message: $COMMIT_MSG"
    echo "Timestamp at start of setup: $(date)"
  } >> "$LOG_FILE"

  cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j8 || { echo "CMake build failed for commit $COMMIT" >> "$LOG_FILE"; exit 1; }
  echo "Setup completed for commit $COMMIT at $(date)" >> "$LOG_FILE"
}
export -f setup_function

prepare_function() {
  rm -rf "$DATA_DIR"/*
  sync
  echo 3 > /proc/sys/vm/drop_caches
  echo "Cleared data directory and dropped caches for commit $COMMIT at $(date)" >> "$LOG_FILE"
}
export -f prepare_function

cleanup_function() {
  {
    echo "Data directory size after benchmark run for commit $COMMIT: $(du -sh "$DATA_DIR" | cut -f1)"
    echo "Number of files in data directory: $(ls "$DATA_DIR" | wc -l)"
  } >> "$LOG_FILE"

  echo "Starting bitcoind for $COMMIT at $(date)" >> "$LOG_FILE"
  ./build/src/bitcoind -datadir="$DATA_DIR" -daemon -dbcache="$DBCACHE" -printtoconsole=0 && sleep 5

  {
    echo "Benchmarking gettxoutsetinfo at $(date)" >> "$LOG_FILE"
    time ./build/src/bitcoin-cli -datadir="$DATA_DIR" gettxoutsetinfo >> "$LOG_FILE"
  } >> "$LOG_FILE" 2>&1

  echo "Stopping bitcoind for $COMMIT at $(date)" >> "$LOG_FILE"
  ./build/src/bitcoin-cli -datadir="$DATA_DIR" stop && sleep 10
  pkill bitcoind; pkill vmstat

  echo "Ended $COMMIT: $COMMIT_MSG at $(date)" >> "$LOG_FILE"
}
export -f cleanup_function

run_bitcoind_with_monitoring() {
  vmstat 1 > "$STORAGE_PATH/vmstat_${COMMIT}_$(date +%Y%m%d%H%M%S).log" &
  VMSTAT_PID=$!

  echo "Starting bitcoind process with commit $COMMIT at $(date)" >> "$LOG_FILE"
  ./build/src/bitcoind -datadir="$DATA_DIR" -stopatheight="$STOP_AT_HEIGHT" -dbcache="$DBCACHE" -printtoconsole=0

  echo "VMSTAT monitoring for commit $COMMIT at $(date)" >> "$LOG_FILE"
  vmstat -s >> "$LOG_FILE"
  kill $VMSTAT_PID
}
export -f run_bitcoind_with_monitoring

run_benchmarks() {
  hyperfine \
    --shell=bash \
    --runs "$RUNS" \
    --show-output \
    --export-json "$JSON_FILE" \
    --parameter-list COMMIT "$COMMIT_LIST" \
    --setup 'COMMIT={COMMIT} setup_function' \
    --prepare 'COMMIT={COMMIT} prepare_function' \
    --cleanup 'COMMIT={COMMIT} cleanup_function' \
    "COMMIT={COMMIT} run_bitcoind_with_monitoring"
}

# Example:
# ./benchmark_script.sh /mnt/my_storage rocksdb-optimized 1 100000 450 "4d689d459338403a3e00d9c1c0d502d1ab711892,d46d5eaa7066f4aa9aea1d333b49ac3a686efc37,c23f9061a5f55893c60cb291c2b1a4e8129f3b6a,7e9243cab6808be496db35c534ce8b43b547f255,7194797b38af751913c5cdfa0081a74290ecb24b,23694f88f2725bbf22c5e00033c58a87fb94a9ec,54de6428fc5477c090b1c1f4b554157272cb62ef,e72af5c99f9276a6b16b7283d995eb64bf4b4b6f,36d680002d77a1ddb426ee96fe671f9a1c89d3a6,master" || {echo "failed"}
run_benchmarks
