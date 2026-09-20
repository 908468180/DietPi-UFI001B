// SPDX-License-Identifier: GPL-2.0-only
/*
 * lk2nd-rproc.c - disable Qualcomm remoterprocs at runtime and return their
 * reserved memory (= carve-outs) to the kernel.
 *
 * Ported from the lk2nd history (commit 64d3c6c, lk2nd/lk2nd-rproc.c,
 * msm8916-mainline/lk2nd) and adapted to the current DEV_TREE_UPDATE() hook:
 *
 *   - The obsolete fs_boot / "/mnt/lk2nd_rproc_mode" runtime mode detection
 *     does not exist in current lk2nd anymore. The mode is now a compile-time
 *     constant (LK2ND_RPROC_MODE, see below).
 *   - The audio re-routing to LPASS only runs in RPROC_MODE_NONE (all remote
 *     procs disabled).  With RPROC_MODE_NO_MODEM (the default used to free the
 *     modem carve-out) adsp stays enabled, so the existing Q6 audio path must
 *     not be touched.
 */

#include <boot.h>
#include <debug.h>
#include <libfdt.h>
#include <string.h>

#include <lk2nd/util/lkfdt.h>

/**
 * rproc_mode - how many remote processors should be disabled.
 *
 * Must be one of:
 *   RPROC_MODE_ALL      - keep everything (no-op)
 *   RPROC_MODE_NO_MODEM - only disable the modem (mpss)
 *   RPROC_MODE_NONE     - disable all remoteprocs AND venus, re-route audio
 *
 * Override at build time with "DEFINES += LK2ND_RPROC_MODE=RPROC_MODE_NO_MODEM".
 */
enum rproc_mode {
	RPROC_MODE_UNKNOWN,
	RPROC_MODE_ALL,
	RPROC_MODE_NO_MODEM,
	RPROC_MODE_NONE,
};

#ifndef LK2ND_RPROC_MODE
#define LK2ND_RPROC_MODE RPROC_MODE_ALL
#endif

static void lk2nd_delete_rmem(void *fdt, int rmem, int node)
{
	const uint32_t *phandle;
	uint32_t handle;
	int len;

	if (node < 0)
		return;

	phandle = fdt_getprop(fdt, node, "memory-region", &len);
	if (len < 0)
		return;
	if (len != sizeof(uint32_t))
		return;

	handle = fdt32_to_cpu(*phandle);
	fdt_for_each_subnode(node, fdt, rmem) {
		if (fdt_get_phandle(fdt, node) == handle) {
			/* NOP node to effectively delete it */
			fdt_nop_node(fdt, node);
			return;
		}
	}
}

static void lk2nd_disable_rproc(void *fdt, const char *name, int rproc, int rmem,
				enum rproc_mode mode)
{
	int ret = fdt_subnode_offset(fdt, rproc, "mpss");
	if (ret < 0 && mode == RPROC_MODE_NO_MODEM)
		/* Only disable modem with RPROC_MODE_NO_MODEM */
		return;

	dprintf(INFO, "lk2nd-rproc: disabling %s\n", name);

	/* Disable both remote proc and reserved memory */
	ret = fdt_setprop_string(fdt, rproc, "status", "disabled");
	if (ret) {
		dprintf(CRITICAL, "lk2nd-rproc: failed to disable %s: %d\n", name, ret);
		return;
	}

	/* Delete reserved memory regions as well */
	lk2nd_delete_rmem(fdt, rmem, rproc);
	lk2nd_delete_rmem(fdt, rmem, fdt_subnode_offset(fdt, rproc, "mpss"));
	lk2nd_delete_rmem(fdt, rmem, fdt_subnode_offset(fdt, rproc, "mba"));
}

/* From qcom,q6afe.h */
#define PRIMARY_MI2S_RX		16
#define PRIMARY_MI2S_TX		17
#define SECONDARY_MI2S_RX	18
#define SECONDARY_MI2S_TX	19
#define TERTIARY_MI2S_RX	20
#define TERTIARY_MI2S_TX	21
#define QUATERNARY_MI2S_RX	22
#define QUATERNARY_MI2S_TX	23
#define QUINARY_MI2S_RX		127
#define QUINARY_MI2S_TX		128

/* From qcom,lpass.h */
#define MI2S_PRIMARY	0
#define MI2S_SECONDARY	1
#define MI2S_TERTIARY	2
#define MI2S_QUATERNARY	3
#define MI2S_QUINARY	4

static uint32_t lk2nd_audio_q6afe_to_lpass(uint32_t id)
{
	switch (id) {
	case PRIMARY_MI2S_RX:
	case PRIMARY_MI2S_TX:
		return MI2S_PRIMARY;
	case SECONDARY_MI2S_RX:
	case SECONDARY_MI2S_TX:
		return MI2S_SECONDARY;
	case TERTIARY_MI2S_RX:
	case TERTIARY_MI2S_TX:
		return MI2S_TERTIARY;
	case QUATERNARY_MI2S_RX:
	case QUATERNARY_MI2S_TX:
		return MI2S_QUATERNARY;
	case QUINARY_MI2S_RX:
	case QUINARY_MI2S_TX:
		return MI2S_QUINARY;
	default:
		return -1;
	}
}

static void lk2nd_audio_dai_remap_to_lpass(void *fdt, int dai, uint32_t lpass)
{
	uint32_t *daip;
	uint32_t new_id;
	int len;

	daip = fdt_getprop_w(fdt, dai, "sound-dai", &len);
	if (len != 2 * sizeof(*daip)) {
		dprintf(CRITICAL, "lk2nd-rproc: sound-dai has weird length: %d\n", len);
		return;
	}

	new_id = lk2nd_audio_q6afe_to_lpass(fdt32_to_cpu(daip[1]));
	if (new_id == -1) {
		dprintf(CRITICAL, "lk2nd-rproc: don't understand q6afe id: %d\n",
			fdt32_to_cpu(daip[1]));
		return;
	}

	/* Remap to LPASS */
	daip[0] = cpu_to_fdt32(lpass);
	daip[1] = cpu_to_fdt32(new_id);
}

static void lk2nd_audio_reroute_to_lpass(void *fdt, int sound, uint32_t lpass)
{
	int node, ret;
	int to_nop = -FDT_ERR_NOTFOUND;

	ret = fdt_setprop_string(fdt, sound, "compatible", "qcom,apq8016-sbc-sndcard");
	if (ret) {
		dprintf(CRITICAL, "lk2nd-rproc: failed to update sound compatible: %d\n", ret);
		return;
	}

	fdt_for_each_subnode(node, fdt, sound) {
		int dai;

		if (to_nop >= 0) {
			fdt_nop_node(fdt, to_nop);
			to_nop = -FDT_ERR_NOTFOUND;
		}

		if (!lkfdt_node_is_available(fdt, node))
			continue; /* meh */

		dai = fdt_subnode_offset(fdt, node, "codec");
		if (dai < 0) {
			/* Don't need DAI links without codec so NOP it next iteration */
			to_nop = node;
			continue;
		}

		/* Get rid of platform { sound-dai = <&q6routing>; }; */
		dai = fdt_subnode_offset(fdt, node, "platform");
		if (dai < 0) {
			dprintf(CRITICAL, "lk2nd-rproc: confused about DAI link without platform\n");
			continue;
		}
		fdt_nop_node(fdt, dai);

		dai = fdt_subnode_offset(fdt, node, "cpu");
		if (dai < 0) {
			dprintf(CRITICAL, "lk2nd-rproc: confused about DAI link without CPU\n");
			continue;
		}

		/*
		 * Now the real magic! sound-dai = <&q6afedai PRIMARY_MI2S_RX>;
		 * needs to become sound-dai = <&lpass MI2S_PRIMARY>;
		 */
		lk2nd_audio_dai_remap_to_lpass(fdt, dai, lpass);
	}

	if (to_nop >= 0)
		fdt_nop_node(fdt, to_nop);
}

static void lk2nd_audio_enable_lpass(void *fdt, int lpass, int sound)
{
	uint32_t phandle;
	int ret;

	if (sound < 0) {
		dprintf(CRITICAL, "lk2nd-rproc: Cannot find sound node: %d\n", sound);
		return;
	}

	if (!lkfdt_node_is_available(fdt, sound)) {
		dprintf(INFO, "lk2nd-rproc: Sound is not enabled in fdt\n");
		return;
	}
	if (lkfdt_node_is_available(fdt, lpass)) {
		dprintf(INFO, "lk2nd-rproc: LPASS already enabled in fdt\n");
		return;
	}

	dprintf(INFO, "lk2nd-rproc: Enabling LPASS and re-routing audio\n");

	/* Enable LPASS */
	fdt_setprop_string(fdt, lpass, "status", "okay");

	phandle = fdt_get_phandle(fdt, lpass);
	if (!phandle) {
		ret = fdt_generate_phandle(fdt, &phandle);
		if (ret) {
			dprintf(CRITICAL, "lk2nd-rproc: Cannot generate phandle for lpass: %d\n", ret);
			return;
		}
		ret = fdt_setprop_u32(fdt, lpass, "phandle", phandle);
		if (ret) {
			dprintf(CRITICAL, "lk2nd-rproc: Cannot set phandle for lpass: %d\n", ret);
			return;
		}
	}

	lk2nd_audio_reroute_to_lpass(fdt, sound, phandle);
}

static void lk2nd_disable_rprocs(void *fdt, enum rproc_mode mode)
{
	int soc = fdt_path_offset(fdt, "/soc");
	int rmem = fdt_path_offset(fdt, "/reserved-memory");
	int sound = -FDT_ERR_NOTFOUND;
	int node;

	if (soc < 0 || rmem < 0) {
		dprintf(CRITICAL, "lk2nd-rproc: can't find offsets soc %d rmem %d\n",
			soc, rmem);
		return;
	}

	fdt_for_each_subnode(node, fdt, soc) {
		const char *name;
		int len;

		name = fdt_get_name(fdt, node, &len);
		if (!name)
			continue;

		/* Match all remoteprocs and venus */
		if (strncmp(name, "remoteproc@", strlen("remoteproc@")) == 0 ||
		    strncmp(name, "video-codec@", strlen("video-codec@")) == 0) {
			lk2nd_disable_rproc(fdt, name, node, rmem, mode);
			continue;
		}

		/* Re-route audio only if ALL remote procs (incl. adsp) are gone */
		if (mode == RPROC_MODE_NONE) {
			if (strncmp(name, "sound@", strlen("sound@")) == 0) {
				sound = node;
				continue;
			}

			if (strncmp(name, "audio-controller@", strlen("audio-controller@")) == 0) {
				lk2nd_audio_enable_lpass(fdt, node, sound);
				continue;
			}
		}
	}

	/* Disable memshare and GPS mem for now */
	node = fdt_path_offset(fdt, "/memshare");
	if (node > 0)
		fdt_setprop_string(fdt, node, "status", "disabled");

	node = fdt_subnode_offset(fdt, rmem, "gps");
	if (node > 0)
		fdt_nop_node(fdt, node);
}

static int lk2nd_rproc_dt_update(void *dtb, const char *cmdline, enum boot_type boot_type)
{
	if (boot_type & (BOOT_DOWNSTREAM | BOOT_LK2ND))
		return 0;

	if (LK2ND_RPROC_MODE <= RPROC_MODE_ALL)
		/* Just keep everything as-is for now */
		return 0;

	lk2nd_disable_rprocs(dtb, LK2ND_RPROC_MODE);
	return 0;
}
DEV_TREE_UPDATE(lk2nd_rproc_dt_update);