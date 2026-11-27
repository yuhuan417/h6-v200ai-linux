/*
 * v200ai FEL eMMC tool - DRAM payload.
 *
 * Runs in DRAM, called by the SPL stub after DRAM init. Everything that is
 * constrained inside SPL (32 KiB SRAM, no console, no libc) lives here
 * instead: read, write, boot-partition switch, clock changes.
 *
 * The SPL exports a small function table; this file never calls into U-Boot
 * symbols directly, so it can be built as a freestanding binary.
 */

typedef unsigned int u32;
typedef unsigned long long u64;

#define API_MAGIC	0x50415049u	/* 'PAPI' */
#define PAR_MAGIC	0x50505230u	/* 'PPR0' */
#define PAYLOAD_MAGIC	0x504C5931u	/* 'PLY1' */

/* The magic word and entry offset live at offset 0/4, written by link.ld. */

struct api {
	u32 magic;
	u32 version;
	int (*mmc_init_all)(void *bis);
	void *(*find_mmc)(int dev);
	int (*mmc_init)(void *mmc);
	void *(*blk_desc)(void *mmc);
	u64 (*blk_read)(void *desc, u64 start, u64 cnt, void *dst);
	u64 (*blk_write)(void *desc, u64 start, u64 cnt, const void *src);
	int (*set_clock)(void *mmc, u32 clock, int disable);
	int (*switch_part)(void *mmc, u32 part);
	u64 (*timer)(u32 start);
	u64 (*capacity)(void *mmc);
	u32 ram_size;
	u32 rsv;
};

struct par {
	u32 magic;	/* in: 'PPR0' */
	u32 op;		/* in: 0 init, 1 read, 2 write, 3 chunked read, 4 chunked write */
	u32 sect;	/* in: first LBA */
	u32 cnt;	/* in: block count */
	u32 dst;	/* in: DRAM address */
	u32 clock;	/* in: 0 = leave as is, else Hz */
	u32 result;	/* out: 0 ok, else stage code */
	u32 err;	/* out: mmc_init() return */
	u32 got;	/* out: blocks transferred */
	u32 lba;	/* out: media size in blocks */
	u32 t0;		/* out: timer before */
	u32 t1;		/* out: timer after */
	u32 dev;	/* in: mmc device number, default 1 */
	u32 part;	/* in: 0 user, 1 boot0, 2 boot1 */
};

#define CHUNK_BLKS	16	/* larger single transfers wedge sunxi_mmc */
#define CHUNK_MAX	512	/* per-run request limit */

static struct {
	struct api *a;
	struct par *p;
	void *mmc;
} ctx;

static int prepare(void)
{
	struct api *a = ctx.a;
	struct par *p = ctx.p;
	int ret;

	p->result = 0;
	p->err = 0;
	p->got = 0;
	p->t0 = (u32)a->timer(0);

	a->mmc_init_all(0);
	ctx.mmc = a->find_mmc((int)p->dev);
	if (!ctx.mmc) {
		p->result = 10;
		return -1;
	}
	ret = a->mmc_init(ctx.mmc);
	p->err = (u32)ret;
	if (!ret)
		p->lba = (u32)a->capacity(ctx.mmc);
	if (ret) {
		p->result = 11;
		return -1;
	}
	if (p->part <= 2) {
		ret = a->switch_part(ctx.mmc, p->part);
		if (ret) {
			p->result = 12;
			return -1;
		}
	}
	if (p->clock) {
		ret = a->set_clock(ctx.mmc, p->clock, 0);
		if (ret) {
			p->result = 13;
			return -1;
		}
	}
	return 0;
}

void __attribute__((section(".text.entry")))
payload(struct api *api, struct par *par)
{
	struct api *a;
	struct par *p;
	void *desc;
	u32 off, step;
	u64 r;

	if (!api || !par || api->magic != API_MAGIC || par->magic != PAR_MAGIC)
		return;

	ctx.a = api;
	ctx.p = par;
	a = api;
	p = par;

	if (p->dev == 0xffffffffu)
		p->dev = 1;
	if (p->op <= 2 && p->cnt > CHUNK_MAX)
		p->cnt = CHUNK_MAX;

	if (p->op == 0) {	/* init only */
		prepare();
		p->t1 = (u32)a->timer(0);
		return;
	}

	if (prepare())
		goto out;

	desc = a->blk_desc(ctx.mmc);
	if (!desc) {
		p->result = 14;
		goto out;
	}

	switch (p->op) {
	case 1:		/* single read */
		p->got = (u32)a->blk_read(desc, p->sect, p->cnt,
					  (void *)(u64)p->dst);
		p->result = (p->got == p->cnt) ? 0 : 20;
		break;
	case 2:		/* single write */
		p->got = (u32)a->blk_write(desc, p->sect, p->cnt,
					   (const void *)(u64)p->dst);
		p->result = (p->got == p->cnt) ? 0 : 21;
		break;
	case 3:		/* chunked read, no single request above CHUNK_BLKS */
	case 4:		/* chunked write */
		for (off = 0; off < p->cnt; off += step) {
			step = p->cnt - off;
			if (step > CHUNK_BLKS)
				step = CHUNK_BLKS;
			if (p->op == 3)
				r = a->blk_read(desc, p->sect + off, step,
					(void *)((u64)p->dst + (u64)off * 512));
			else
				r = a->blk_write(desc, p->sect + off, step,
					(const void *)((u64)p->dst + (u64)off * 512));
			p->got += (u32)r;
			if (r != step)
				break;
		}
		p->result = (p->got == p->cnt) ? 0 : (p->op == 3 ? 30 : 31);
		break;
	default:
		p->result = 2;
		break;
	}

out:
	p->t1 = (u32)a->timer(0);
}
