#!/usr/bin/env bash

## This script is to run the complete GEC system on any given test set

set -e
set -x

source ../paths.sh

if [[ $# -ge 6 ]]; then
    input_file=$1
    output_dir=$2
    device=$3
    model_path=$4
    DATA_BIN_DIR=$5
    BPE_MODEL_DIR=$6
    if [[ $# -ge 8 ]]; then
        reranker_weights=$7
        reranker_feats=$8
        if [[ "${reranker_feats}" == "eolm" || "${reranker_feats}" == "lm" ]]; then
            lm_url=$9
            if [[ ! -f ${lm_url} ]]; then
                echo "Language model not found: ${lm_url}"
                exit -2
            fi
        fi
    fi
else
    echo "Usage: `basename $0` <input_file> <output_dir> <GPU device id to use(e.g: 0)> <path to model_file/dir> <dir to bin data> <dir to BPE model> [optional args: <path-to-reranker-weights> <features, e.g: 'eo' or 'lm' or 'eolm'> <trained language model's url>]"
    exit -1
fi


NBEST_RERANKER=${SOFTWARE_DIR}/nbest-reranker
beam=12
nbest=${beam}
threads=12

if [[ -d "$model_path" ]]; then
    models=`ls ${model_path}/*pt | tr '\n' ' '`
    models=${models//pt /pt:}
    models=${models/%:/''}
#    models=`ls ${model_path}/*pt | tr '\n' ' ' | sed "s| \([^$]\)| --path \1|g"`
    echo ${models}
elif [[ -f "$model_path" ]]; then
    models=${model_path}
elif [[ ! -e "$model_path" ]]; then
    echo "Model path not found: $model_path"
    exit -3
fi

mkdir -p ${output_dir}
if [[ -d "$BPE_MODEL_DIR" ]]; then
    ${SCRIPTS_DIR}/apply_bpe.py -c ${BPE_MODEL_DIR}/train.bpe.model < ${input_file} > ${output_dir}/input.bpe.txt
    beam_search_input=${output_dir}/input.bpe.txt
else
    beam_search_input=${input_file}
fi

beam_search_starttime=$(date +%s)
# running fairseq on the test data
CUDA_VISIBLE_DEVICES="${device}" python ${FAIRSEQPY}/interactive.py \
    --no-progress-bar \
    --path ${models} \
    --beam ${beam} --nbest ${nbest} \
    --model-overrides "{'encoder_embed_path': None, 'decoder_embed_path': None}" \
    ${DATA_BIN_DIR} < ${beam_search_input} > ${output_dir}/beamsearch.output.nbest.txt
beam_search_endtime=$(date +%s)
cost=$((beam_search_endtime - beam_search_starttime))
echo "beam search end. cost ${cost}s"

# getting best hypotheses
cat ${output_dir}/beamsearch.output.nbest.txt | grep "^H"  | python -c "import sys; x = sys.stdin.readlines(); x = ' '.join([ x[i] for i in range(len(x)) if(i%$nbest == 0) ]); print(x)" | cut -f3 > ${output_dir}/beamsearch.output.txt

if [[ -d "$BPE_MODEL_DIR" ]]; then
    # debpe
    cat ${output_dir}/beamsearch.output.txt | sed 's|@@ ||g' | sed '$ d' > ${output_dir}/output.tok.txt
else
    cat ${output_dir}/beamsearch.output.txt | sed '$d' > ${output_dir}/output.tok.txt
fi

# additionally re-rank outputs
if [[ $# -ge 8 ]]; then
    if [[ "${reranker_feats}" == "eo" ]]; then
        featstring="EditOps(name='EditOps0')"
    elif [[ "${reranker_feats}" == "lm" ]]; then
        featstring="LM('LM0', '$lm_url', normalize=False), WordPenalty(name='WordPenalty0')"
    elif [[ "${reranker_feats}" == "eolm" ]]; then
        featstring="EditOps(name='EditOps0'), LM('LM0', '$lm_url', normalize=False), WordPenalty(name='WordPenalty0')"
    else
        echo "Unknown re-ranker features string. got ${reranker_feats}"
        exit -4
    fi

    rerank_starttime=$(date +%s)

    if [[ -d "$BPE_MODEL_DIR" ]]; then
        ${SCRIPTS_DIR}/nbest_reformat.py -i ${output_dir}/beamsearch.output.nbest.txt --debpe -o ${output_dir}/output.tok.nbest.reformat.txt
    else
        ${SCRIPTS_DIR}/nbest_reformat.py -i ${output_dir}/beamsearch.output.nbest.txt -o ${output_dir}/output.tok.nbest.reformat.txt
    fi
    ${NBEST_RERANKER}/augmenter.py -s ${input_file} -i ${output_dir}/output.tok.nbest.reformat.txt -o ${output_dir}/output.tok.nbest.reformat.augmented.txt -f "$featstring"
    ${NBEST_RERANKER}/rerank.py -i ${output_dir}/output.tok.nbest.reformat.augmented.txt -w ${reranker_weights} -o ${output_dir} --clean-up
    mv ${output_dir}/output.tok.nbest.reformat.augmented.txt.reranked.1best ${output_dir}/output.reranked.tok.txt

    rerank_endtime=$(date +%s)
    cost=$((rerank_endtime - rerank_starttime))
    echo "re-rank end. cost ${cost}s"
fi
