"""Share fused decode operands with their source quantized projections."""

from __future__ import annotations

import functools

import mlx.core as mx


def share_fused_projection_storage(linears):
    """Rebind source projections to row views of their cached fused operands."""
    first = linears[0]
    cached = first._fused_decode_linears
    if cached is getattr(first, "_omlx_shared_fused_decode_linears", None):
        return cached

    _, weights, scales, biases, split_indices = cached
    bounds = [0, *split_indices, weights.shape[0]]
    for linear, start, stop in zip(linears, bounds, bounds[1:]):
        linear.weight = weights[start:stop]
        linear.scales = scales[start:stop]
        linear.biases = biases[start:stop]

    mx.eval([(linear.weight, linear.scales, linear.biases) for linear in linears])
    cache_key = tuple(
        (id(linear.weight), id(linear.scales), id(linear.biases)) for linear in linears
    )
    shared = (cache_key, weights, scales, biases, split_indices)
    first._fused_decode_linears = shared
    first._omlx_shared_fused_decode_linears = shared
    return shared


def apply_fused_projection_storage_patch() -> bool:
    """Compact mlx-vlm's fused projection cache after it is first created."""
    from mlx_vlm.speculative.ops import linear as ops

    original = ops._decode_quantized_linears_fused
    if getattr(original, "_omlx_shared_projection_storage", False):
        return False

    @functools.wraps(original)
    def fused(linears, x):
        result = original(linears, x)
        if result is not None:
            share_fused_projection_storage(linears)
        return result

    fused._omlx_shared_projection_storage = True
    ops._decode_quantized_linears_fused = fused
    return True
