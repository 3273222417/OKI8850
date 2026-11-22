#!/usr/bin/env python3
"""Adapt the 6.12 zram ZSTD backend to the ZSTD 1.5.7 kernel wrapper API."""

from pathlib import Path
import sys


SOURCE = r'''// SPDX-License-Identifier: GPL-2.0-or-later

#include <linux/errno.h>
#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/zstd.h>

#include "backend_zstd.h"

struct zstd_ctx {
	zstd_cctx *cctx;
	zstd_dctx *dctx;
	void *cctx_mem;
	void *dctx_mem;
};

struct zstd_params {
	zstd_parameters cprm;
};

static void zstd_release_params(struct zcomp_params *params)
{
	struct zstd_params *zp = params->drv_data;

	params->drv_data = NULL;
	kfree(zp);
}

static int zstd_setup_params(struct zcomp_params *params)
{
	struct zstd_params *zp;

	if (params->dict_sz)
		return -EOPNOTSUPP;
	if (params->level == ZCOMP_PARAM_NO_LEVEL)
		params->level = clamp_t(int, 3, zstd_min_clevel(), zstd_max_clevel());
	if (params->level < zstd_min_clevel() || params->level > zstd_max_clevel())
		return -EINVAL;

	zp = kzalloc(sizeof(*zp), GFP_KERNEL);
	if (!zp)
		return -ENOMEM;

	params->drv_data = zp;
	zp->cprm = zstd_get_params(params->level, PAGE_SIZE);
	return 0;
}

static void zstd_destroy(struct zcomp_ctx *ctx)
{
	struct zstd_ctx *zctx = ctx->context;

	if (!zctx)
		return;
	vfree(zctx->cctx_mem);
	vfree(zctx->dctx_mem);
	kfree(zctx);
	ctx->context = NULL;
}

static int zstd_create(struct zcomp_params *params, struct zcomp_ctx *ctx)
{
	struct zstd_ctx *zctx;
	struct zstd_params *zp = params->drv_data;
	size_t size;

	if (params->dict_sz)
		return -EOPNOTSUPP;
	if (!zp)
		return -EINVAL;
	zctx = kzalloc(sizeof(*zctx), GFP_KERNEL);
	if (!zctx)
		return -ENOMEM;
	ctx->context = zctx;

	size = zstd_cctx_workspace_bound(&zp->cprm.cParams);
	zctx->cctx_mem = vzalloc(size);
	if (!zctx->cctx_mem)
		goto error;
	zctx->cctx = zstd_init_cctx(zctx->cctx_mem, size);
	if (!zctx->cctx)
		goto error;

	size = zstd_dctx_workspace_bound();
	zctx->dctx_mem = vzalloc(size);
	if (!zctx->dctx_mem)
		goto error;
	zctx->dctx = zstd_init_dctx(zctx->dctx_mem, size);
	if (!zctx->dctx)
		goto error;
	return 0;

error:
	zstd_destroy(ctx);
	return -ENOMEM;
}

static int zstd_compress(struct zcomp_params *params, struct zcomp_ctx *ctx,
			 struct zcomp_req *req)
{
	struct zstd_params *zp = params->drv_data;
	struct zstd_ctx *zctx = ctx->context;
	size_t ret;

	ret = zstd_compress_cctx(zctx->cctx, req->dst, req->dst_len,
				 req->src, req->src_len, &zp->cprm);
	if (zstd_is_error(ret))
		return -EINVAL;
	req->dst_len = ret;
	return 0;
}

static int zstd_decompress(struct zcomp_params *params, struct zcomp_ctx *ctx,
			   struct zcomp_req *req)
{
	struct zstd_ctx *zctx = ctx->context;
	size_t ret;

	ret = zstd_decompress_dctx(zctx->dctx, req->dst, req->dst_len,
				   req->src, req->src_len);
	if (zstd_is_error(ret))
		return -EINVAL;
	return 0;
}

const struct zcomp_ops backend_zstd = {
	.compress	= zstd_compress,
	.decompress	= zstd_decompress,
	.create_ctx	= zstd_create,
	.destroy_ctx	= zstd_destroy,
	.setup_params	= zstd_setup_params,
	.release_params	= zstd_release_params,
	.name		= "zstd",
};
'''


def main() -> None:
	if len(sys.argv) != 2:
		raise SystemExit("usage: adapt_zram_zstd_backend.py common-source")
	common = Path(sys.argv[1]).resolve()
	target = common / "drivers/block/zram/backend_zstd.c"
	if not target.is_file():
		raise SystemExit(f"missing zram ZSTD backend: {target}")
	old = target.read_text(encoding="utf-8")
	if "zstd_create_cdict_byreference" not in old and "zstd_get_cparams" not in old:
		raise SystemExit("zram ZSTD backend does not match the expected legacy API")
	target.write_text(SOURCE, encoding="utf-8", newline="\n")
	new = target.read_text(encoding="utf-8")
	for symbol in ("zstd_custom_mem", "zstd_create_cdict_byreference", "zstd_get_cparams", "zstd_compress_using_cdict"):
		if symbol in new:
			raise SystemExit(f"legacy ZSTD API remains after adaptation: {symbol}")
	print(f"Adapted {target} to workspace-based ZSTD 1.5.7 APIs")


if __name__ == "__main__":
	main()
