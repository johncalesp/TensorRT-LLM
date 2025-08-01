/*
 * Copyright (c) 2019-2025, NVIDIA CORPORATION.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "mlaChunkedPrefill.cuh"
#include "tensorrt_llm/common/assert.h"
#include "tensorrt_llm/common/cudaTypeUtils.cuh"
#include "tensorrt_llm/common/mathUtils.h"
#include <cuda_fp8.h>
#include <cutlass/array.h>
#include <cutlass/half.h>

namespace
{

template <typename T>
struct MergeSoftmaxTraits
{
    static constexpr int kQKNopeSize = 128;
    static constexpr int kHeadSize = kQKNopeSize;

    static constexpr int kBytesPerElem = sizeof(T);
    static constexpr int kBytesPerLoad = 16;
    static constexpr int kElemPerThread = kBytesPerLoad / sizeof(T);
    static_assert((kHeadSize * kBytesPerElem) % kBytesPerLoad == 0,
        "kHeadSize * kBytesPerElem must be multiple of kBytesPerLoad (16Bytes)");
    static constexpr int kVecPerHead = (kHeadSize * kBytesPerElem) / kBytesPerLoad;
    static constexpr int kTokenPerBlock
        = std::is_same_v<T, float> ? 4 : 8; // for each block, we fetch 8 token for fp16, 4 tokens for fp32.
    static constexpr int kNumThreads = kVecPerHead * kTokenPerBlock;

    union VecReader
    {
        cutlass::Array<T, kElemPerThread> data;
        uint4 reader;
        static_assert(
            sizeof(uint4) == sizeof(cutlass::Array<T, kElemPerThread>), "Size mismatch for MergeSoftmaxTraits");
    };
};

template <typename T>
struct loadChunkedKVKernelTraits
{
    static constexpr int kLoraSize = 512;
    static constexpr int kRopeSize = 64;
    static constexpr int kHeadSize = kLoraSize + kRopeSize;
    using VecT = uint4;
    static constexpr int kBytesPerElem = sizeof(T);
    static constexpr int kBytesPerLoad = 16;
    static constexpr int kElemPerLoad = kBytesPerLoad / kBytesPerElem;
    static_assert((kHeadSize * kBytesPerElem) % kBytesPerLoad == 0,
        "kHeadSize * kBytesPerElem must be multiple of kBytesPerLoad (16Bytes)");
    static constexpr int kVecPerHead = (kHeadSize * kBytesPerElem) / kBytesPerLoad;
    static constexpr int kThreadPerHead = kVecPerHead; // for each head, we use kThreadPerHead threads to fetch all the
                                                       // kv cache data, each thread read kv cache only once.
    static constexpr int kTokenPerBlock
        = std::is_same_v<T, float> ? 4 : 8;            // for each block, we fetch 8 token for fp16, 4 tokens for fp32.
    static constexpr int kBlockSize = kThreadPerHead * kTokenPerBlock;
    static constexpr int kKVThreadPerHead = (kLoraSize * kBytesPerElem) / kBytesPerLoad;
};

template <typename T>
struct setChunkedKVKernelTraits
{
    using VecT = uint4;
    static constexpr int kQKNopeSize = 128;
    static constexpr int kVHeadSize = 128;
    static_assert(kQKNopeSize == kVHeadSize);
    static constexpr int kRopeSize = 64;
    static constexpr int kHeadSize = kQKNopeSize + kRopeSize;
    static constexpr int kBytesPerElem = sizeof(T);
    static constexpr int kBytesPerLoad = 16;
    static constexpr int kElemPerLoad = kBytesPerLoad / kBytesPerElem;
    static_assert((kHeadSize * kBytesPerElem) % kBytesPerLoad == 0,
        "kHeadSize * kBytesPerElem must be multiple of kBytesPerLoad (16Bytes)");
    static constexpr int kThreadPerHead = (kHeadSize * kBytesPerElem) / kBytesPerLoad;
    static constexpr int kKVThreadPerHead = (kQKNopeSize * kBytesPerElem) / kBytesPerLoad;
    static constexpr int kCpTokenPerBlock = 16;
    static constexpr int kBlockSize = kThreadPerHead * kCpTokenPerBlock;
};

template <typename SrcType, int NUM>
inline __device__ void quantCopy(
    __nv_fp8_e4m3* dst_global_ptr, SrcType const* src_fragment_ptr, float const scale_val = 1.f)
{
    using DstVecType = typename std::conditional<sizeof(SrcType) == 2, float2, float>::type;
    using SrcType2 = typename std::conditional<sizeof(SrcType) == 2,
        typename tensorrt_llm::common::TypeConverter<SrcType>::Type, float2>::type;
    static constexpr int COPY_SIZE = sizeof(DstVecType);
    static constexpr int TOTAL_COPY_SIZE = NUM * sizeof(__nv_fp8_e4m3);
    static constexpr int LOOP_NUM = TOTAL_COPY_SIZE / COPY_SIZE;
    static_assert(TOTAL_COPY_SIZE % COPY_SIZE == 0);
    static constexpr int CVT_NUM = COPY_SIZE / sizeof(__nv_fp8_e4m3) / 2;
    static_assert(COPY_SIZE % (sizeof(__nv_fp8_e4m3) * 2) == 0);
    DstVecType fragment;
    int offset = 0;
#pragma unroll
    for (int i = 0; i < LOOP_NUM; ++i)
    {
#pragma unroll
        for (int j = 0; j < CVT_NUM; ++j)
        {
            float2 val2 = tensorrt_llm::common::cuda_cast<float2>(
                reinterpret_cast<SrcType2 const*>(src_fragment_ptr)[j + offset]);
            val2.x *= scale_val;
            val2.y *= scale_val;
            reinterpret_cast<__nv_fp8x2_e4m3*>(&fragment)[j] = __nv_fp8x2_e4m3(val2);
        }
        reinterpret_cast<DstVecType*>(dst_global_ptr)[i] = fragment;
        offset += CVT_NUM;
    }
}

template <typename DstType, int NUM>
inline __device__ void dequantCopy(
    DstType* dst_global_ptr, __nv_fp8_e4m3 const* src_fragment_ptr, float const scale_val = 1.f)
{
    using DstVecType = uint4;
    using DstType2
        = std::conditional_t<sizeof(DstType) == 2, typename tensorrt_llm::common::TypeConverter<DstType>::Type, float2>;
    static constexpr int COPY_SIZE = sizeof(DstVecType);
    static constexpr int TOTAL_COPY_SIZE = NUM * sizeof(DstType);
    static constexpr int LOOP_NUM = TOTAL_COPY_SIZE / COPY_SIZE;
    static_assert(TOTAL_COPY_SIZE % COPY_SIZE == 0);
    static constexpr int CVT_NUM = COPY_SIZE / sizeof(DstType) / 2;
    static_assert(COPY_SIZE % (sizeof(DstType) * 2) == 0);
    DstVecType fragment;
    int offset = 0;
#pragma unroll
    for (int i = 0; i < LOOP_NUM; ++i)
    {
#pragma unroll
        for (int j = 0; j < CVT_NUM; ++j)
        {
            float2 val2 = tensorrt_llm::common::cuda_cast<float2>(
                reinterpret_cast<__nv_fp8x2_e4m3 const*>(src_fragment_ptr)[j + offset]);
            val2.x *= scale_val;
            val2.y *= scale_val;
            reinterpret_cast<DstType2*>(&fragment)[j] = tensorrt_llm::common::cuda_cast<DstType2>(val2);
        }
        reinterpret_cast<DstVecType*>(dst_global_ptr)[i] = fragment;
        offset += CVT_NUM;
    }
}

// merged_attn [q_total_len, H=128, D=128] (T)
// merged_softmax_sum [q_total_len, H, 2] (float, max/sum)
template <typename T>
__global__ void mergeAttnWithSoftmaxKernel(T* merged_attn, float2* merged_softmax_stats, T const* pre_attn,
    float2 const* pre_softmax_stats, T const* curr_attn, float2 const* curr_softmax_stats, int64_t const* cu_q_seq_len,
    int64_t const* merge_op, int const num_heads, int const head_size)
{
    using KT = MergeSoftmaxTraits<T>;
    int const batch_idx = static_cast<int>(blockIdx.y);
    int const head_idx = static_cast<int>(blockIdx.z);

    int64_t merge_op_val = merge_op[batch_idx];
    if (merge_op_val == 0)
    {
        return; // skip this batch
    }

    size_t const head_dim_vec_idx = (threadIdx.x % KT::kVecPerHead);
    size_t const head_dim_idx = head_dim_vec_idx * KT::kElemPerThread;

    if (merge_op_val == 0)
    {
        return; // skip this batch
    }
    int const curr_q_len = static_cast<int>(cu_q_seq_len[batch_idx + 1] - cu_q_seq_len[batch_idx]);
    int const global_q_offset = cu_q_seq_len[batch_idx];

    for (int local_token_idx = (threadIdx.x / KT::kVecPerHead) + blockIdx.x * KT::kTokenPerBlock;
         local_token_idx < curr_q_len; local_token_idx += gridDim.x * KT::kTokenPerBlock)
    {
        // load softmax stat
        int const global_softmax_stats_offset = (global_q_offset + local_token_idx) * num_heads + head_idx;
        float2 curr_stats = curr_softmax_stats[global_softmax_stats_offset];
        // hack, current softmax stats max is not multiplied by bmm1_scale
        // TODO: delete this line when trtllm gen kernel return the right max value.
        curr_stats.x *= 0.072168784; // 1 / sqrt(128 + 64), head_size is 128 for output, but for bmm1 is 192
        float2 pre_stats = pre_softmax_stats[global_softmax_stats_offset];

        // load attn
        typename KT::VecReader pre_attn_reader{};
        typename KT::VecReader curr_attn_reader{};
        typename KT::VecReader merged_attn_reader{};

        int const global_attn_offset
            = (global_q_offset + local_token_idx) * num_heads * head_size + head_idx * head_size;

        pre_attn_reader.reader
            = *reinterpret_cast<decltype(pre_attn_reader.reader) const*>(pre_attn + global_attn_offset + head_dim_idx);
        curr_attn_reader.reader = *reinterpret_cast<decltype(curr_attn_reader.reader) const*>(
            curr_attn + global_attn_offset + head_dim_idx);

        // only copy curr attn and curr softmax sum
        if (merge_op_val == 2)
        {
            *reinterpret_cast<decltype(merged_attn_reader.reader)*>(merged_attn + global_attn_offset + head_dim_idx)
                = curr_attn_reader.reader;
            if (head_dim_idx == 0)
            {
                merged_softmax_stats[global_softmax_stats_offset] = curr_stats;
            }
        }
        else
        {
            // merge attn and softmax stats
            float2 merged_stats;
            merged_stats.x = fmaxf(pre_stats.x, curr_stats.x);
            float pre_shift = std::exp(pre_stats.x - merged_stats.x);
            float curr_shift = std::exp(curr_stats.x - merged_stats.x);
            merged_stats.y = (pre_stats.y * pre_shift + curr_stats.y * curr_shift);
            for (int i = 0; i < KT::kElemPerThread; ++i)
            {
                merged_attn_reader.data[i]
                    = (static_cast<float>(pre_attn_reader.data[i]) * pre_stats.y * pre_shift
                          + static_cast<float>(curr_attn_reader.data[i]) * curr_stats.y * curr_shift)
                    / merged_stats.y;
            }
            // write merged attn back to global memory
            *reinterpret_cast<decltype(merged_attn_reader.reader)*>(merged_attn + global_attn_offset + head_dim_idx)
                = merged_attn_reader.reader;
            // write merged softmax stats back to global memory
            if (head_dim_idx == 0)
            {
                merged_softmax_stats[global_softmax_stats_offset] = merged_stats;
            }
        }
    }
}

// kv_output {total_chunk_token=b*chunk_size, h=1, d_lora}
// k_pe_output {total_chunk_token, h=1, d_rope}
template <typename T, typename TCache>
__global__ void loadChunkedKVCacheForMLAKernel(T* output_kv_ptr, T* output_k_pe_ptr,
    tensorrt_llm::kernels::KVBlockArray const kv_cache, int64_t const* cu_ctx_chunked_len, int chunked_size,
    int chunked_idx, float const* kv_scale_quant_orig_ptr)
{
    static_assert(std::is_same_v<T, TCache> || std::is_same_v<TCache, __nv_fp8_e4m3>,
        "TCache must be either the same type as T or __nv_fp8_e4m3");
    using KT = loadChunkedKVKernelTraits<TCache>;
    float const kv_scale_quant_orig = kv_scale_quant_orig_ptr ? kv_scale_quant_orig_ptr[0] : 1.0f;
    int const batch_idx = static_cast<int>(blockIdx.y);
    [[maybe_unused]] int const head_idx = static_cast<int>(blockIdx.z); // default 0

    size_t const head_dim_vec_idx = (threadIdx.x % KT::kVecPerHead);
    size_t const head_dim_idx = head_dim_vec_idx * KT::kElemPerLoad;

    int64_t const real_chunked_size = cu_ctx_chunked_len[batch_idx + 1] - cu_ctx_chunked_len[batch_idx];
    int64_t const global_st_offset = cu_ctx_chunked_len[batch_idx];
    if (real_chunked_size <= 0)
    {
        return; // no kv cache for this batch
    }
    bool const is_valid_kv = head_dim_vec_idx < KT::kKVThreadPerHead;
    for (int local_token_idx = (threadIdx.x / KT::kThreadPerHead) + blockIdx.x * KT::kTokenPerBlock;
         local_token_idx < real_chunked_size; local_token_idx += gridDim.x * KT::kTokenPerBlock)
    {
        int token_idx_in_kv_cache = (chunked_idx * chunked_size) + local_token_idx;
        bool const valid_token = (local_token_idx < chunked_size);
        if (valid_token)
        {
            auto* kvSrc = reinterpret_cast<T*>(kv_cache.getKBlockPtr(batch_idx, token_idx_in_kv_cache));
            // head_idx === 0
            auto kvBlockIdx
                = kv_cache.getKVLocalIdx(token_idx_in_kv_cache, 0, KT::kVecPerHead, static_cast<int>(head_dim_vec_idx));
            auto ld_data = (reinterpret_cast<typename KT::VecT*>(kvSrc))[kvBlockIdx];
            if (is_valid_kv)
            {
                // kv_output {total_chunk_token, h=1, d}
                int const global_st_idx
                    = global_st_offset * KT::kLoraSize + local_token_idx * KT::kLoraSize + head_dim_idx;
                if constexpr (std::is_same_v<TCache, T>)
                {
                    *reinterpret_cast<typename KT::VecT*>(output_kv_ptr + global_st_idx) = ld_data;
                }
                else if constexpr (std::is_same_v<TCache, __nv_fp8_e4m3>)
                {
                    dequantCopy<T, KT::kElemPerLoad>(output_kv_ptr + global_st_idx,
                        reinterpret_cast<__nv_fp8_e4m3 const*>(&ld_data), kv_scale_quant_orig);
                }
            }
            else
            {
                // k_pe_output {total_chunk_token, h=1, d_rope}
                int const global_st_idx = global_st_offset * KT::kRopeSize + local_token_idx * KT::kRopeSize
                    + (head_dim_idx - KT::kLoraSize);

                if constexpr (std::is_same_v<TCache, T>)
                {
                    *reinterpret_cast<typename KT::VecT*>(output_k_pe_ptr + global_st_idx) = ld_data;
                }
                else if constexpr (std::is_same_v<TCache, __nv_fp8_e4m3>)
                {
                    dequantCopy<T, KT::kElemPerLoad>(output_k_pe_ptr + global_st_idx,
                        reinterpret_cast<__nv_fp8_e4m3 const*>(&ld_data), kv_scale_quant_orig);
                }
            }
        }
    }
}

// in the most of cases, chunk_size =  max_seq_len
// output_kv {B, 2, ceil(max_seq_len / kv_cache_tokens_per_block), h, kv_cache_tokens_per_block, d}, padding with
// zero
// kv {token_size = B*chunked_unit_size, 2, H=128, uncompressed_h=128}, k_pe {token_size = B*chunked_unit_size, h=1,
// rope_h}
// cu_seq_lens {batch + 1}, fake cu_seq_len, for chunked prefill is {0, chunk_size, chunk_size * 2 ....}
template <typename T>
__global__ void setChunkedKVCacheForMLAKernel(T* output_kv, T const* kv, T const* k_pe, int const max_seq_len,
    int const num_heads, int uncompressed_head_size, int rope_size, int64_t const* cu_seq_lens,
    int kv_cache_tokens_per_block)
{
    using KT = setChunkedKVKernelTraits<T>;
    int const batch_idx = static_cast<int>(blockIdx.y);
    int const head_idx = static_cast<int>(blockIdx.z);
    int const head_dim_vec_idx = (threadIdx.x % KT::kThreadPerHead);
    int const head_dim_idx = head_dim_vec_idx * KT::kElemPerLoad;
    bool const is_valid_kv = head_dim_idx < KT::kQKNopeSize;

    int64_t const global_token_offset = cu_seq_lens[batch_idx];
    int64_t const cache_kv_len = cu_seq_lens[batch_idx + 1] - cu_seq_lens[batch_idx];
    int const kv_cache_block_num = (max_seq_len + kv_cache_tokens_per_block - 1) / kv_cache_tokens_per_block;
    int const kv_cache_block_size = num_heads * kv_cache_tokens_per_block * (uncompressed_head_size + rope_size);
    int64_t const offset_for_kv_in_mem_pool = kv_cache_block_num * kv_cache_block_size;
    int64_t const kv_offset = num_heads * uncompressed_head_size;
    size_t const seq_len_loop_end = cache_kv_len;
    for (int local_token_idx = (threadIdx.x / KT::kThreadPerHead) + blockIdx.x * KT::kCpTokenPerBlock;
         local_token_idx < seq_len_loop_end; local_token_idx += gridDim.x * KT::kCpTokenPerBlock)
    {
        if (local_token_idx >= cache_kv_len)
        {
            break;
        }
        if (is_valid_kv)
        {

            int64_t ld_kv_global_offset
                = int64_t(global_token_offset + local_token_idx) * 2 * num_heads * uncompressed_head_size
                + head_idx * uncompressed_head_size;
            int64_t ld_kv_local_offset = head_dim_vec_idx;
            auto k_data = (reinterpret_cast<typename KT::VecT const*>(kv + ld_kv_global_offset))[ld_kv_local_offset];
            auto v_data = (reinterpret_cast<typename KT::VecT const*>(
                kv + kv_offset + ld_kv_global_offset))[ld_kv_local_offset];

            int64_t st_k_global_offset = int64_t(batch_idx) * 2 * offset_for_kv_in_mem_pool
                + local_token_idx / kv_cache_tokens_per_block * kv_cache_block_size
                + head_idx * kv_cache_tokens_per_block * (uncompressed_head_size + rope_size)
                + (local_token_idx % kv_cache_tokens_per_block) * (uncompressed_head_size + rope_size);
            int64_t st_v_global_offset = st_k_global_offset + offset_for_kv_in_mem_pool;
            int64_t st_k_local_offset = head_dim_vec_idx;
            int64_t st_v_local_offset = head_dim_vec_idx;
            (reinterpret_cast<typename KT::VecT*>(output_kv + st_k_global_offset))[st_k_local_offset] = k_data;
            (reinterpret_cast<typename KT::VecT*>(output_kv + st_v_global_offset))[st_v_local_offset] = v_data;
        }
        else
        {
            // rope h = 1
            int64_t ld_rope_global_offset = int64_t(global_token_offset + local_token_idx) * rope_size;
            int64_t ld_rope_local_offset = head_dim_vec_idx - KT::kKVThreadPerHead;
            auto rope_data
                = (reinterpret_cast<typename KT::VecT const*>(k_pe + ld_rope_global_offset))[ld_rope_local_offset];
            int64_t st_rope_global_offset = int64_t(batch_idx) * 2 * offset_for_kv_in_mem_pool
                + local_token_idx / kv_cache_tokens_per_block * kv_cache_block_size
                + head_idx * kv_cache_tokens_per_block * (uncompressed_head_size + rope_size)
                + (local_token_idx % kv_cache_tokens_per_block) * (uncompressed_head_size + rope_size);
            int64_t st_rope_local_offset = head_dim_vec_idx;
            (reinterpret_cast<typename KT::VecT*>(output_kv + st_rope_global_offset))[st_rope_local_offset] = rope_data;
        }
    }
}

} // namespace

namespace tensorrt_llm
{
namespace kernels
{

// merged_attn [q_total_len, H=128, D=128] (T)
// merged_softmax_sum [q_total_len, H, 2] (float), the first part is the max value for each
// row of P = QK^T, the second part is the softmax sum
// if merge_op[b] == 0, we just skip this batch, if merge_op[b] == 1, we merge the pre-attn and curr-attn, if
// merge_op[b]
// == 2, we only copy curr_attn and curr_softmax_sum to merged_attn and merged_softmax_sum
template <typename T>
void invokeMergeAttnWithSoftmax(T* merged_attn, float* merged_softmax_stats, T const* pre_attn,
    float const* pre_softmax_stats, T const* curr_attn, float const* curr_softmax_stats, int const batch_size,
    int64_t const* cu_q_seq_len, int max_q_seq_len, int64_t const* merge_op, int const num_heads, int const head_size,
    cudaStream_t stream)
{
    using KT = MergeSoftmaxTraits<T>;
    TLLM_CHECK_WITH_INFO(head_size == KT::kHeadSize, "head dim should be equal to %d", KT::kHeadSize);

    dim3 grid(static_cast<int>(tensorrt_llm::common::divUp(max_q_seq_len, KT::kTokenPerBlock)), batch_size, num_heads);
    dim3 block(KT::kNumThreads);

    mergeAttnWithSoftmaxKernel<T><<<grid, block, 0, stream>>>(merged_attn,
        reinterpret_cast<float2*>(merged_softmax_stats), pre_attn, reinterpret_cast<float2 const*>(pre_softmax_stats),
        curr_attn, reinterpret_cast<float2 const*>(curr_softmax_stats), cu_q_seq_len, merge_op, num_heads, head_size);
}

// load single chunk kv from kv_cache for each request
template <typename T, typename TCache>
void invokeMLALoadChunkedKV(T* output_kv_ptr, T* output_k_pe_ptr, KVBlockArray const& kv_cache, int const num_contexts,
    int64_t const* cu_ctx_chunked_len, int lora_size, int rope_size, int chunked_size, int chunked_idx,
    float const* kv_scale_quant_orig_ptr, cudaStream_t stream)
{
    using KT = loadChunkedKVKernelTraits<TCache>;
    TLLM_CHECK_WITH_INFO(lora_size + rope_size == KT::kHeadSize, "head dim should be equal to %d", KT::kHeadSize);
    TLLM_CHECK_WITH_INFO(lora_size == KT::kLoraSize, "lora dim should be equal to %d", KT::kLoraSize);
    TLLM_CHECK_WITH_INFO(rope_size == KT::kRopeSize, "rope dim should be equal to %d", KT::kRopeSize);
    // {chunked_unit_size / token_per_block, batch_size, head_num}
    dim3 grid(static_cast<int>(tensorrt_llm::common::divUp(chunked_size, KT::kTokenPerBlock)), num_contexts, 1);
    loadChunkedKVCacheForMLAKernel<T, TCache><<<grid, KT::kBlockSize, 0, stream>>>(output_kv_ptr, output_k_pe_ptr,
        kv_cache, cu_ctx_chunked_len, chunked_size, chunked_idx, kv_scale_quant_orig_ptr);
}

// output_kv {B, 2, ceil(chunked_size / kv_cache_tokens_per_block), h, kv_cache_tokens_per_block, d}, padding with
// zero
// kv {total_token, 2, H, uncompressed_h=128} 0 for k and 1 for v, k_pe {total_token, h=1, rope_h}
// input kv and k_pe can be cached tokens or uncached tokens
template <typename T>
void invokeMLASetChunkedKV(T* output_kv, T const* kv, T const* k_pe, int const batch_size, int const max_seq_len,
    int const num_heads, int uncompressed_head_size, int rope_size, int64_t const* cu_seq_lens,
    int const kv_cache_tokens_per_block, cudaStream_t stream)
{
    using KT = setChunkedKVKernelTraits<T>;
    TLLM_CHECK_WITH_INFO(
        uncompressed_head_size + rope_size == KT::kHeadSize, "head dim should be equal to %d", KT::kHeadSize);
    TLLM_CHECK_WITH_INFO(kv_cache_tokens_per_block % KT::kCpTokenPerBlock == 0,
        "kv_cache_tokens_per_block should be multiple of %d", KT::kCpTokenPerBlock);

    dim3 grid(tensorrt_llm::common::divUp(max_seq_len, KT::kCpTokenPerBlock), batch_size, num_heads);
    setChunkedKVCacheForMLAKernel<T><<<grid, KT::kBlockSize, 0, stream>>>(output_kv, kv, k_pe, max_seq_len, num_heads,
        uncompressed_head_size, rope_size, cu_seq_lens, kv_cache_tokens_per_block);
}

#define INSTANTIATE_MLA_CHUNKED_PREFILL_KERNEL(T)                                                                      \
    template void invokeMergeAttnWithSoftmax<T>(T * merged_attn, float* merged_softmax_stats, T const* pre_attn,       \
        float const* pre_softmax_stats, T const* curr_attn, float const* curr_softmax_stats, int const batch_size,     \
        int64_t const* cu_q_seq_len, int max_q_seq_len, int64_t const* merge_op, int const num_heads,                  \
        int const head_size, cudaStream_t stream);                                                                     \
    template void invokeMLALoadChunkedKV<T, T>(T * output_kv_ptr, T * output_k_pe_ptr, KVBlockArray const& kv_cache,   \
        int const num_contexts, int64_t const* cu_ctx_chunked_len, int lora_size, int rope_size, int chunked_size,     \
        int chunked_idx, float const* kv_scale_quant_orig_ptr, cudaStream_t stream);                                   \
    template void invokeMLALoadChunkedKV<T, __nv_fp8_e4m3>(T * output_kv_ptr, T * output_k_pe_ptr,                     \
        KVBlockArray const& kv_cache, int const num_contexts, int64_t const* cu_ctx_chunked_len, int lora_size,        \
        int rope_size, int chunked_size, int chunked_idx, float const* kv_scale_quant_orig_ptr, cudaStream_t stream);  \
    template void invokeMLASetChunkedKV<T>(T * output_kv, T const* kv, T const* k_pe, int const batch_size,            \
        int const max_seq_len, int const num_heads, int uncompressed_head_size, int rope_size,                         \
        int64_t const* cu_seq_lens, int const kv_cache_tokens_per_block, cudaStream_t stream);

INSTANTIATE_MLA_CHUNKED_PREFILL_KERNEL(half);
INSTANTIATE_MLA_CHUNKED_PREFILL_KERNEL(float);
INSTANTIATE_MLA_CHUNKED_PREFILL_KERNEL(__nv_bfloat16);
} // namespace kernels
} // namespace tensorrt_llm
