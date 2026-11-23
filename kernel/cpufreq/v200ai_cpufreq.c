// SPDX-License-Identifier: GPL-2.0-only
/*
 * H6 V200-AI 的时钟降频温控。
 *
 * 本板 DTB 声明了 AXP805/806（cpu-supply），但该 PMIC 的 I²C 探测超时，
 * 依赖调压的 cpufreq-dt/DVFS 无法使用。本模块只经过已有的 CPU 时钟驱动调频，
 * 保留启动电压，不访问 PMIC；上限取 min(启动时钟, 888 MHz)，只能降不能升。
 *
 * 频率全部取自本板 DTB 的 CPU OPP 表。CPUFREQ_IS_COOLING_DEV 把 policy 注册成
 * cpufreq-cpu0 cooling device，接管 DTB 里已有的 85 °C 被动降温(2 °C 回滞)与
 * 100 °C critical；本模块不改阈值、不改 governor。
 */
#include <linux/clk.h>
#include <linux/cpu.h>
#include <linux/cpufreq.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/thermal.h>
#include <linux/workqueue.h>

static struct clk *cpu_clk;
static unsigned long ceiling_hz;
static struct cpufreq_frequency_table rates[] = {
	{ .frequency = 480000 },
	{ .frequency = 720000 },
	{ .frequency = 816000 },
	{ .frequency = 888000 },
	{ .frequency = CPUFREQ_TABLE_END },
};

/* 本板 cpu-thermal 温区的 polling delay 为 0，没有硬件中断就不会再采样；
 * 这里每秒主动触发一次，沿用温区已有的 trips 和 step_wise policy。
 */
static void poll_temperature(struct work_struct *work);
static DECLARE_DELAYED_WORK(thermal_poll, poll_temperature);

static void poll_temperature(struct work_struct *work)
{
	struct thermal_zone_device *zone;

	zone = thermal_zone_get_zone_by_name("cpu-thermal");
	if (!IS_ERR(zone))
		thermal_zone_device_update(zone, THERMAL_EVENT_UNSPECIFIED);
	schedule_delayed_work(&thermal_poll, msecs_to_jiffies(1000));
}

static int set_rate(struct cpufreq_policy *policy, unsigned int index)
{
	unsigned long hz = policy->freq_table[index].frequency * 1000UL;

	if (hz > ceiling_hz)
		return -EINVAL;
	return clk_set_rate(cpu_clk, hz);
}

static int init_policy(struct cpufreq_policy *policy)
{
	policy->clk = cpu_clk;
	/* 四个 A53 共用一个 CPU 时钟和一条温控上限。 */
	cpufreq_generic_init(policy, rates, 250000);
	return 0;
}

static struct cpufreq_driver driver = {
	.name = "v200ai-clock",
	.flags = CPUFREQ_CONST_LOOPS | CPUFREQ_IS_COOLING_DEV,
	.init = init_policy,
	.verify = cpufreq_generic_frequency_table_verify,
	.target_index = set_rate,
	.get = cpufreq_generic_get,
	.attr = cpufreq_generic_attr,
};

static int __init v200ai_init(void)
{
	struct device *cpu;
	unsigned long boot_hz;
	int i, ret;

	if (!of_machine_is_compatible("custom,h6-v200ai") ||
	    !of_machine_is_compatible("allwinner,sun50i-h6"))
		return -ENODEV;
	cpu = get_cpu_device(0);
	if (!cpu)
		return -ENODEV;
	cpu_clk = of_clk_get(cpu->of_node, 0);
	if (IS_ERR(cpu_clk))
		return PTR_ERR(cpu_clk);

	boot_hz = clk_get_rate(cpu_clk);
	ceiling_hz = min(boot_hz, 888000000UL);
	if (ceiling_hz < 480000000UL) {
		ret = -EINVAL;
		goto put_clock;
	}
	for (i = 0; rates[i].frequency != CPUFREQ_TABLE_END; i++) {
		unsigned long hz = rates[i].frequency * 1000UL;

		if (hz > ceiling_hz)
			rates[i].frequency = CPUFREQ_ENTRY_INVALID;
		else if (clk_round_rate(cpu_clk, hz) != hz) {
			ret = -EINVAL;
			goto put_clock;
		}
	}
	ret = cpufreq_register_driver(&driver);
	if (ret)
		goto put_clock;
	schedule_delayed_work(&thermal_poll, 0);
	pr_info("v200ai-cpufreq: boot=%lu kHz ceiling=%lu kHz, voltage unchanged\n",
		boot_hz / 1000, ceiling_hz / 1000);
	return 0;

put_clock:
	clk_put(cpu_clk);
	return ret;
}

static void __exit v200ai_exit(void)
{
	cancel_delayed_work_sync(&thermal_poll);
	cpufreq_unregister_driver(&driver);
	clk_put(cpu_clk);
}

module_init(v200ai_init);
module_exit(v200ai_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("H6 V200-AI clock-only CPU cooling capped at boot frequency");
MODULE_SOFTDEP("pre: sun8i_thermal");
