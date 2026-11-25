// SPDX-License-Identifier: GPL-3.0-or-later
// ProjectTenshin — Snapdragon big.LITTLE / Tri-Cluster Linux ARM64 thread affinity helper.
//
// Evolved from ProjectDural's thread_affinity.h for Qualcomm Snapdragon SoCs
// (SD845, SD865/870, SD888, SD8 Gen 1/2/3, Snapdragon G3x Gen 2) running Linux
// ARM64 (ROCKNIX, Arch ARM64, PostmarketOS, Debian, Ubuntu, PortMaster).
//
// Key principles learned from real handheld profiling:
// 1. Always parse `/sys/devices/system/cpu/online` (sparse masks like "0,4-7"
//    occur when power policies hot-unplug cores; naming an offline core makes
//    pthread_setaffinity_np fail with EINVAL).
// 2. On heterogeneous Snapdragon SoCs (Silver + Gold + Prime), classify cores by
//    `cpufreq/cpuinfo_max_freq` so the latency-critical Xbox guest/fiber thread
//    runs on the Prime/Gold performance cluster while SDL3, audio, and Mesa
//    Freedreno/Turnip Vulkan worker threads stay free across all online CPUs.
#pragma once

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#if defined(__linux__)
#include <pthread.h>
#include <sched.h>
#include <unistd.h>
#endif

namespace projecttenshin::arm64 {

struct CpuCoreInfo {
    int id = 0;
    unsigned long max_freq_khz = 0;
    bool online = true;
};

struct ClusterTopology {
    std::vector<CpuCoreInfo> cores;
    std::vector<int> prime_cores; // highest-frequency tier
    std::vector<int> gold_cores;  // mid/high-performance tier (or == prime on dual-cluster)
    std::vector<int> silver_cores;
    bool heterogeneous = false;
};

// Parse Linux cpulist syntax such as "0-3", "0,2-3,6-7", or "0-7\n".
inline std::vector<int> parse_cpulist(const char *text) {
    std::vector<int> out;
    if (!text) return out;
    const char *p = text;
    while (*p) {
        while (*p == ' ' || *p == '\t' || *p == ',' || *p == '\n' || *p == '\r') ++p;
        if (!*p) break;
        char *end = nullptr;
        long lo = std::strtol(p, &end, 10);
        if (end == p || lo < 0 || lo >= 1024) break;
        long hi = lo;
        p = end;
        if (*p == '-') {
            ++p;
            long parsed_hi = std::strtol(p, &end, 10);
            if (end != p && parsed_hi >= lo && parsed_hi < 1024) {
                hi = parsed_hi;
                p = end;
            }
        }
        for (long c = lo; c <= hi; ++c) {
            if (std::find(out.begin(), out.end(), static_cast<int>(c)) == out.end()) {
                out.push_back(static_cast<int>(c));
            }
        }
        while (*p && *p != ',') ++p;
    }
    std::sort(out.begin(), out.end());
    return out;
}

inline std::vector<int> read_online_cpus() {
#if defined(__linux__)
    if (FILE *f = std::fopen("/sys/devices/system/cpu/online", "r")) {
        char buf[256]{};
        if (std::fgets(buf, sizeof(buf), f)) {
            std::fclose(f);
            auto parsed = parse_cpulist(buf);
            if (!parsed.empty()) return parsed;
        } else {
            std::fclose(f);
        }
    }
    const long n = ::sysconf(_SC_NPROCESSORS_ONLN);
    std::vector<int> fallback;
    for (long i = 0; i < (n > 0 ? n : 1); ++i) fallback.push_back(static_cast<int>(i));
    return fallback;
#else
    return {0};
#endif
}

inline unsigned long read_cpu_max_freq_khz(int cpu_id) {
#if defined(__linux__)
    char path[128];
    std::snprintf(path, sizeof(path),
        "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", cpu_id);
    if (FILE *f = std::fopen(path, "r")) {
        unsigned long khz = 0;
        if (std::fscanf(f, "%lu", &khz) != 1) khz = 0;
        std::fclose(f);
        if (khz > 0) return khz;
    }
    std::snprintf(path, sizeof(path),
        "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_max_freq", cpu_id);
    if (FILE *f = std::fopen(path, "r")) {
        unsigned long khz = 0;
        if (std::fscanf(f, "%lu", &khz) != 1) khz = 0;
        std::fclose(f);
        return khz;
    }
#else
    (void)cpu_id;
#endif
    return 0;
}

// Classify a list of (core_id, max_freq_khz) into Prime / Gold / Silver clusters.
inline ClusterTopology classify_topology(const std::vector<CpuCoreInfo> &cores) {
    ClusterTopology topo;
    topo.cores = cores;
    if (cores.empty()) return topo;

    std::vector<unsigned long> tiers;
    for (const auto &c : cores) {
        if (c.max_freq_khz == 0) continue;
        // Merge frequencies within 50 MHz into the same tier.
        bool matched = false;
        for (unsigned long t : tiers) {
            unsigned long diff = (c.max_freq_khz > t) ? (c.max_freq_khz - t) : (t - c.max_freq_khz);
            if (diff <= 50000ul) {
                matched = true;
                break;
            }
        }
        if (!matched) tiers.push_back(c.max_freq_khz);
    }
    std::sort(tiers.begin(), tiers.end(), std::greater<unsigned long>());

    if (tiers.size() <= 1) {
        topo.heterogeneous = false;
        for (const auto &c : cores) {
            topo.prime_cores.push_back(c.id);
            topo.gold_cores.push_back(c.id);
        }
        return topo;
    }

    topo.heterogeneous = true;
    const unsigned long top_freq = tiers.front();
    const unsigned long low_freq = tiers.back();

    for (const auto &c : cores) {
        if (c.max_freq_khz + 50000ul >= top_freq) {
            topo.prime_cores.push_back(c.id);
            topo.gold_cores.push_back(c.id);
        } else if (tiers.size() >= 3 && c.max_freq_khz > low_freq + 50000ul) {
            topo.gold_cores.push_back(c.id);
        } else {
            topo.silver_cores.push_back(c.id);
        }
    }
    return topo;
}

inline ClusterTopology detect_topology() {
    std::vector<CpuCoreInfo> cores;
    for (int id : read_online_cpus()) {
        cores.push_back({id, read_cpu_max_freq_khz(id), true});
    }
    return classify_topology(cores);
}

inline bool set_current_thread_cpus(const std::vector<int> &cpus) {
#if defined(__linux__)
    if (cpus.empty()) return false;
    cpu_set_t set;
    CPU_ZERO(&set);
    int added = 0;
    for (int c : cpus) {
        if (c >= 0 && c < CPU_SETSIZE) {
            CPU_SET(c, &set);
            ++added;
        }
    }
    if (added == 0) return false;
    return ::pthread_setaffinity_np(::pthread_self(), sizeof(set), &set) == 0;
#else
    (void)cpus;
    return false;
#endif
}

// Allow the current thread (and any driver/audio/Vulkan worker threads it spawns)
// to run on every online core so Mesa Freedreno/Turnip workers are never trapped
// on a single CPU.
inline bool unpin_current_thread_all_online() {
    return set_current_thread_cpus(read_online_cpus());
}

// Pin the guest execution thread to the Snapdragon Prime/Gold performance cluster
// (only when heterogeneous clusters are detected, or if explicitly requested via
// PROJECTTENSHIN_PIN_PERF=1). Never fails fatally.
inline bool pin_guest_thread_performance_cluster() {
    const char *env = std::getenv("PROJECTTENSHIN_PIN_PERF");
    if (env && std::strcmp(env, "0") == 0) {
        return false;
    }
    const ClusterTopology topo = detect_topology();
    if (!topo.heterogeneous) {
        return false;
    }
    const auto &target = !topo.gold_cores.empty() ? topo.gold_cores : topo.prime_cores;
    if (target.empty()) return false;
    const bool ok = set_current_thread_cpus(target);
    if (ok) {
        std::fprintf(stderr,
            "[ProjectTenshin] Snapdragon big.LITTLE detected (%zu online cores: %zu prime, %zu perf, %zu silver) -> guest pinned to perf cluster\n",
            topo.cores.size(), topo.prime_cores.size(), target.size(), topo.silver_cores.size());
    }
    return ok;
}

inline void set_current_thread_name(const char *name) {
#if defined(__linux__)
    if (name) ::pthread_setname_np(::pthread_self(), name);
#else
    (void)name;
#endif
}

} // namespace projecttenshin::arm64
