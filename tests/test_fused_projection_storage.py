"""Fused GDN projection caches must not retain a second packed weight bank."""

import gc

import mlx.core as mx
import mlx.nn as nn
import pytest
from mlx_vlm.speculative.ops import linear as ops

from omlx.patches import fused_projection_storage, qwen35_gdn_prework


@pytest.fixture(autouse=True)
def restore_mlx_vlm_fusion(monkeypatch):
    original = ops._decode_quantized_linears_fused
    monkeypatch.setattr(ops, "_decode_quantized_linears_fused", original)


def _projections(
    input_size=256,
    rows=(128, 64, 16, 16),
    bits=4,
    dtype=mx.bfloat16,
):
    linears = [
        nn.QuantizedLinear(input_size, count, bias=False, group_size=64, bits=bits)
        for count in rows
    ]
    for linear in linears:
        linear.set_dtype(dtype)
    mx.eval([linear.parameters() for linear in linears])
    return linears


def _cache_key(linears):
    return tuple(
        (id(linear.weight), id(linear.scales), id(linear.biases)) for linear in linears
    )


@pytest.mark.parametrize("consumer", ["omlx", "mlx-vlm"])
def test_fused_cache_does_not_retain_27b_projection_copy(consumer):
    linears = _projections(5120, (10240, 6144, 48, 48))
    x = mx.zeros((1, 1, 5120), dtype=mx.bfloat16)
    mx.eval(x)
    mx.synchronize()
    gc.collect()
    mx.clear_cache()
    before = mx.get_active_memory()

    if consumer == "omlx":
        assert qwen35_gdn_prework._one_row_fused_projections(linears) is not None
        result = ops._decode_quantized_linears_fused(linears, x)
    else:
        fused_projection_storage.apply_fused_projection_storage_patch()
        result = ops._decode_quantized_linears_fused(linears, x)
        assert result is not None

    mx.eval(result)
    mx.synchronize()
    gc.collect()
    mx.clear_cache()

    cache = linears[0]._fused_decode_linears
    assert cache[0] == _cache_key(linears)
    assert mx.get_active_memory() - before < 1024**2
    mx.eval(ops._decode_quantized_linears_fused(linears, x))
    assert linears[0]._fused_decode_linears is cache


@pytest.mark.parametrize("bits", [2, 3, 4, 5, 6, 8])
@pytest.mark.parametrize("dtype", [mx.float16, mx.bfloat16, mx.float32])
def test_shared_storage_preserves_decode_prefill_and_batch_verify(bits, dtype):
    linears = _projections(bits=bits, dtype=dtype)
    decode = mx.random.normal((1, 1, 256)).astype(dtype)
    prefill = mx.random.normal((1, 64, 256)).astype(dtype)
    batch = mx.random.normal((2, 1, 256)).astype(dtype)
    expected_prefill = tuple(linear(prefill) for linear in linears)
    original = ops._decode_quantized_linears_fused
    expected_decode = original(linears, decode)
    expected_batch = ops._target_verify_linears(linears, batch)
    mx.eval(expected_prefill, expected_decode, expected_batch)

    fused_projection_storage.apply_fused_projection_storage_patch()
    actual_decode = ops._decode_quantized_linears_fused(linears, decode)
    actual_prefill = tuple(linear(prefill) for linear in linears)
    actual_batch = ops._target_verify_linears(linears, batch)
    mx.eval(actual_decode, actual_prefill, actual_batch)

    assert all(
        mx.array_equal(actual, expected).item()
        for actual, expected in zip(actual_decode, expected_decode)
    )
    assert all(
        mx.array_equal(actual, expected).item()
        for actual, expected in zip(actual_prefill, expected_prefill)
    )
    assert all(
        mx.array_equal(actual, expected).item()
        for actual, expected in zip(actual_batch, expected_batch)
    )
    assert linears[0]._fused_decode_linears[0] == _cache_key(linears)


def test_replaced_weight_rebuilds_shared_fused_cache():
    linears = _projections()
    x = mx.ones((1, 1, 256), dtype=mx.bfloat16)
    fused_projection_storage.apply_fused_projection_storage_patch()
    first_output = ops._decode_quantized_linears_fused(linears, x)
    mx.eval(first_output)
    first_cache = linears[0]._fused_decode_linears

    linears[1].weight = mx.zeros_like(linears[1].weight)
    expected = linears[1](x)
    mx.eval(expected)
    actual = ops._decode_quantized_linears_fused(linears, x)
    mx.eval(actual)

    assert linears[0]._fused_decode_linears is not first_cache
    assert mx.array_equal(actual[1], expected).item()
    assert linears[0]._fused_decode_linears[0] == _cache_key(linears)


def test_unsupported_projection_group_keeps_original_weights():
    linears = _projections()[:3]
    weights = tuple(linear.weight for linear in linears)
    result = ops._decode_quantized_linears_fused(
        linears, mx.zeros((1, 1, 256), dtype=mx.bfloat16)
    )
    assert result is None
    assert all(linear.weight is weight for linear, weight in zip(linears, weights))
