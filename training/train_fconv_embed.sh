#!/bin/bash
## This script used to train fconv+Emb model

set -x
set -e

source ../paths.sh

if [[ $# != 7 ]]; then
    echo "Usage: `basename $0` <dir to bin data> <GPU device id to use(e.g: 0)> <model_name(e.g: fconv_zh_bpe_embed)> <embed_file> <random seed> <max tokens> <max sentences>"
    exit -1
fi

DATA_BIN_DIR=$1
gpu_to_use=$2
model_name=$3
EMBED_URL=$4
SEED=$5
MAX_TOKENS=$6
MAX_SENS=$7

if [[ ! -f "${EMBED_URL}" ]]; then
    echo "cannot find embedding file in ${EMBED_URL}"
    exit -1
fi

OUT_DIR=models/${model_name}/model${SEED}/
mkdir -p ${OUT_DIR}

CUDA_VISIBLE_DEVICES="${gpu_to_use}" python ${FAIRSEQPY}/train.py \
    ${DATA_BIN_DIR} \
    --save-dir ${OUT_DIR} \
    -a fconv \
    --fp16 --fp16-init-scale=8 \
    --num-workers=4 --skip-invalid-size-inputs-valid-test \
    --encoder-embed-dim 500 --encoder-embed-path ${EMBED_URL} \
    --decoder-embed-dim 500 --decoder-embed-path ${EMBED_URL} --decoder-out-embed-dim 500 \
    --encoder-layers '[(1024,3)] * 7' --decoder-layers '[(1024,3)] * 7' \
    --dropout 0.2 --clip-norm 0.1 \
    --optimizer nag --momentum 0.99 \
    --lr-scheduler=reduce_lr_on_plateau --lr=0.25 --lr-shrink=0.1 --min-lr=1e-4 \
    --max-epoch 100 \
    --max-tokens ${MAX_TOKENS} --max-sentences ${MAX_SENS} \
    --no-progress-bar --seed ${SEED}

