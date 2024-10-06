#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ] || [ -z "$6" ] || [ -z "$7" ] || [ -z "$8" ]; then
  echo "Usage: $0 /path/to/storage bench_name runs stopatheight assumevalidhash dbcache commit_list bitcoin_src [assumeutxo_snapshot]"
  exit 1
fi

START_DATE=$(date +%Y%m%d%H%M%S)

export STORAGE_PATH="$1"
export BASE_NAME="$2"
export RUNS="$3"
export STOP_AT_HEIGHT="$4"
export ASSUME_VALID_HASH="$5"
export DBCACHE="$6"
export COMMIT_LIST="$7"
export BITCOIN_SRC="$8"

export PROJECT_DIR="$STORAGE_PATH/${BASE_NAME}_${START_DATE}"
export DATA_DIR="$PROJECT_DIR/bitcoin-datadir"
mkdir -p "$PROJECT_DIR"
mkdir -p "$DATA_DIR"

export LOG_FILE="$PROJECT_DIR/benchmark.log"
export JSON_FILE="$PROJECT_DIR/benchmark.json"

prepare_function() {
  echo "Starting prepare step for commit $COMMIT at $(date)" >> "$LOG_FILE"
  git -C "$BITCOIN_SRC" checkout "$COMMIT" || { echo "Failed to checkout commit $COMMIT" >> "$LOG_FILE"; exit 1; }
  cmake -B "$BITCOIN_SRC"/build -DCMAKE_BUILD_TYPE=Release "$BITCOIN_SRC"
  cmake --build "$BITCOIN_SRC"/build -j20
  echo "Build completed for commit $COMMIT at $(date)" >> "$LOG_FILE"
  
  sync
  echo 3 > /proc/sys/vm/drop_caches
  rm -rf "$DATA_DIR"/*
  echo "Cleared data directory and dropped caches for commit $COMMIT at $(date)" >> "$LOG_FILE"
  if [ -n "$ASSUMEUTXO_SNAPSHOT" ]; then
    pushd "$BITCOIN_SRC"
    echo "Presyncing headers for commit $COMMIT at $(date)" >> "$LOG_FILE"
    # stopatheight=1 ensures we presync the headers , which is required to be able to load an assumeutxo
    # snapshot. after headers sync, we restart and load the snapshot
    ./build/src/bitcoind -connect=127.0.0.1:8333 -port=8444 -rpcport=8445 -stopatheight=1 -datadir="$DATA_DIR" -dbcache="$DBCACHE" -printtoconsole=0
    echo "Loading UTXO set from $ASSUMEUTXO_SNAPSHOT for commit $COMMIT at $(date)" >> "$LOG_FILE"
    ./build/src/bitcoind -connect=127.0.0.1:8333 -port=8444 -rpcport=8445 -datadir="$DATA_DIR" -dbcache="$DBCACHE" -daemon && sleep 5
    ./build/src/bitcoin-cli -rpcport=8445 -rpcclienttimeout=0 -datadir="$DATA_DIR" loadtxoutset "$ASSUMEUTXO_SNAPSHOT" >> "$LOG_FILE" 2>&1
    echo "AssumeUTXO snapshot loaded for commit $COMMIT at $(date)" >> "$LOG_FILE"
    ./build/src/bitcoin-cli -rpcport=8445 -datadir="$DATA_DIR" stop && sleep 10 
    popd
  fi
  echo "Finished prepare step for commit $COMMIT at $(date)" >> "$LOG_FILE"
}
export -f prepare_function


cleanup_function() {
  pkill vmstat
  echo "Ended $COMMIT: $COMMIT_MSG at $(date)" >> "$LOG_FILE"

  # Copy binary and data directory to project directory
  COMMIT_DIR=$PROJECT_DIR/$COMMIT
  mkdir -p $COMMIT_DIR
  cp $BITCOIN_SRC/build/src/bitcoind $COMMIT_DIR/
  cp -r $DATA_DIR $COMMIT_DIR/
  rm -r $DATA_DIR/*
  echo "Copied binary and data directory to $COMMIT_DIR" >> "$LOG_FILE"
}
export -f cleanup_function

run_bitcoind_with_monitoring() {
  vmstat 1 > "$PROJECT_DIR/vmstat_${COMMIT}_$(date +%Y%m%d%H%M%S).log" &
  VMSTAT_PID=$!

  echo "Starting bitcoind process with commit $COMMIT at $(date)" >> "$LOG_FILE"
  # sync from a local node to get rid of any network latency / misbehaving peer variance
  # we could also do a -reindex, which goes through the same codepaths for building the chainstate
  # but doesnt need to get blocks over the network. note, -reindex does not work when
  # benching from a loaded assumeutxo snapshot, and can only be used after background validation
  # has full finished
  #
  # NOTE: -pausebackgroundsync is a patched in argument that halts background sync while we sync
  # to chaintip with assumeutxo. this is so background validation doesnt create any noise in the benchmark
  #
  # NOTE: maxmepool=5 and blocksonly is meant to "disable" the mempool. this is so the 300mb for the mempool
  # is not used by coinsdb cache. this ensures whatever we specify for dbcache is representative of the actual
  # memory the node will have during IBD / normal operation
  #
  # NOTE: -connect , port, rpcport can be commented out to do regular IBD from real peers
  pushd "$BITCOIN_SRC"
  ./build/src/bitcoind \
      -datadir="$DATA_DIR" \
      -stopatheight="$STOP_AT_HEIGHT" \
      -assumevalid="$ASSUME_VALID_HASH" \
      -dbcache="$DBCACHE" \
      -printtoconsole=0 \
      -maxmempool=5 \
      -blocksonly \
      -debug=coindb \
      -connect=127.0.0.1:8333 \
      -port=8444 \
      -rpcport=8445 \
      -pausebackgroundsync

  echo "VMSTAT monitoring for commit $COMMIT at $(date)" >> "$LOG_FILE"
  vmstat -s >> "$LOG_FILE"
  kill $VMSTAT_PID
  popd
}
export -f run_bitcoind_with_monitoring

run_benchmarks() {
  hyperfine \
    --shell=bash \
    --runs "$RUNS" \
    --export-json "$JSON_FILE" \
    --parameter-list COMMIT "$COMMIT_LIST" \
    --prepare 'COMMIT={COMMIT} prepare_function' \
    --cleanup 'COMMIT={COMMIT} cleanup_function' \
    "COMMIT={COMMIT} run_bitcoind_with_monitoring"
}

# Example:
# ./assumeutxo_bench.sh /mnt/my_storage mdbx-test 1 100000 450 "318de6e79109687b24a7326da43ee75179ba3c44" bitcoin/
run_benchmarks
