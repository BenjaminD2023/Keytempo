/*
 * External, read-only macOS process CPU-energy sampler. No daemon, UI access,
 * input monitoring, settings changes, or process lifecycle changes.
 *
 * Build: clang -O2 scripts/measure_energy.c -o /tmp/keytempo-measure-energy
 * Run:   /tmp/keytempo-measure-energy PID [SECONDS=180] [INTERVAL=5]
 * Test:  /tmp/keytempo-measure-energy --self-test
 *
 * Requires SDK headers with RUSAGE_INFO_V6. The syscall can be unavailable or
 * denied at runtime; that is reported as unavailable, never as zero watts.
 * Source semantics: Apple's XNU doc/observability/recount.md and kern/task.c.
 * ri_energy_nj is CPU-attributed energy, NOT total app/battery/device energy.
 */
#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#ifndef RUSAGE_INFO_V6
#error "Build this external sampler with a macOS SDK that defines RUSAGE_INFO_V6"
#endif

typedef struct {
    double at;
    struct rusage_info_v6 info;
} EnergySample;

static mach_timebase_info_data_t timebase;

static double monotonic_seconds(void) {
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &time) != 0) {
        perror("clock_gettime");
        exit(1);
    }
    return (double)time.tv_sec + (double)time.tv_nsec / 1e9;
}

static long double ticks_to_seconds(uint64_t ticks) {
    return (long double)ticks * timebase.numer / timebase.denom / 1e9L;
}

static long double cpu_seconds(const struct rusage_info_v6 *info) {
    return ticks_to_seconds(info->ri_user_time) + ticks_to_seconds(info->ri_system_time);
}

static int capture(pid_t pid, EnergySample *sample) {
    memset(sample, 0, sizeof(*sample));
    double before = monotonic_seconds();
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&sample->info) != 0) return errno;
    double after = monotonic_seconds();
    sample->at = before + (after - before) / 2.0;
    return 0;
}

static void sleep_until(double target) {
    for (;;) {
        double remaining = target - monotonic_seconds();
        if (remaining <= 0) return;
        struct timespec delay = {
            .tv_sec = (time_t)remaining,
            .tv_nsec = (long)((remaining - floor(remaining)) * 1e9)
        };
        if (nanosleep(&delay, NULL) != 0 && errno != EINTR) {
            perror("nanosleep");
            exit(1);
        }
    }
}

static void json_string(const char *text) {
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)text; *p; ++p) {
        if (*p == '"' || *p == '\\') printf("\\%c", *p);
        else if (*p < 0x20) printf("\\u%04x", *p);
        else putchar(*p);
    }
    putchar('"');
}

static const char *error_kind(int error) {
    if (error == EPERM || error == EACCES) return "permission_denied";
    if (error == EINVAL || error == ENOTSUP || error == ENOSYS) return "unsupported_flavor_or_platform";
    if (error == ESRCH) return "process_not_found";
    return "read_error";
}

static void print_error(int error) {
    printf("{\"kind\":"); json_string(error_kind(error));
    printf(",\"errno\":%d,\"message\":", error); json_string(strerror(error));
    putchar('}');
}

static void print_sample(const EnergySample *sample, double origin) {
    const struct rusage_info_v6 *info = &sample->info;
    printf("{\"elapsed_seconds\":%.9f,\"cpu_energy_nj\":%" PRIu64
           ",\"performance_core_energy_nj\":%" PRIu64
           ",\"user_mach_ticks\":%" PRIu64 ",\"system_mach_ticks\":%" PRIu64
           ",\"cpu_seconds\":%.12Lf,\"package_idle_wakeups\":%" PRIu64
           ",\"interrupt_wakeups\":%" PRIu64 ",\"disk_bytes_read\":%" PRIu64
           ",\"disk_bytes_written\":%" PRIu64 ",\"logical_write_bytes\":%" PRIu64
           ",\"billed_energy_counter\":%" PRIu64 ",\"serviced_energy_counter\":%" PRIu64
           ",\"resident_bytes\":%" PRIu64 ",\"physical_footprint_bytes\":%" PRIu64 "}",
           sample->at - origin, info->ri_energy_nj, info->ri_penergy_nj,
           info->ri_user_time, info->ri_system_time, cpu_seconds(info),
           info->ri_pkg_idle_wkups, info->ri_interrupt_wkups,
           info->ri_diskio_bytesread, info->ri_diskio_byteswritten, info->ri_logical_writes,
           info->ri_billed_energy, info->ri_serviced_energy,
           info->ri_resident_size, info->ri_phys_footprint);
}

static bool same_process(const EnergySample *first, const EnergySample *sample) {
    return first->info.ri_proc_start_abstime != 0 &&
           first->info.ri_proc_start_abstime == sample->info.ri_proc_start_abstime &&
           memcmp(first->info.ri_uuid, sample->info.ri_uuid, sizeof(first->info.ri_uuid)) == 0;
}

static bool counters_monotonic(const EnergySample *before, const EnergySample *after) {
    return after->at > before->at &&
           after->info.ri_energy_nj >= before->info.ri_energy_nj &&
           after->info.ri_penergy_nj >= before->info.ri_penergy_nj &&
           after->info.ri_user_time >= before->info.ri_user_time &&
           after->info.ri_system_time >= before->info.ri_system_time;
}

static int self_test(void) {
    EnergySample before, after;
    int error = capture(getpid(), &before);
    if (error) {
        printf("{\"self_test_passed\":false,\"error\":"); print_error(error); puts("}");
        return 2;
    }
    volatile uint64_t accumulator = 1;
    double stop = monotonic_seconds() + 0.2;
    do {
        for (unsigned i = 0; i < 4096; ++i) accumulator = accumulator * UINT64_C(6364136223846793005) + 1;
    } while (monotonic_seconds() < stop);
    (void)accumulator;
    // Recount energy is charged at context switches. Yield before taking the
    // second reading so the controlled CPU work has been accounted for.
    sleep_until(monotonic_seconds() + 0.02);
    error = capture(getpid(), &after);
    if (error) {
        printf("{\"self_test_passed\":false,\"error\":"); print_error(error); puts("}");
        return 2;
    }
    bool identity = same_process(&before, &after);
    bool monotonic = counters_monotonic(&before, &after);
    long double seconds = cpu_seconds(&after.info) - cpu_seconds(&before.info);
    bool supported = after.info.ri_energy_nj > 0;
    bool increased = supported && after.info.ri_energy_nj > before.info.ri_energy_nj;
    bool passed = identity && monotonic && increased && seconds > 0;
    printf("{\"self_test_passed\":%s,\"scope\":\"process CPU energy only; controlled own-process CPU work\","
           "\"energy_counter_supported\":%s,\"identity_stable\":%s,\"counters_monotonic\":%s,"
           "\"cpu_energy_before_nj\":%" PRIu64 ",\"cpu_energy_after_nj\":%" PRIu64
           ",\"cpu_seconds_delta\":%.9Lf,\"mach_timebase_numer\":%u,\"mach_timebase_denom\":%u}\n",
           passed ? "true" : "false", supported ? "true" : "false",
           identity ? "true" : "false", monotonic ? "true" : "false",
           before.info.ri_energy_nj, after.info.ri_energy_nj, seconds, timebase.numer, timebase.denom);
    return passed ? 0 : 2;
}

static bool parse_double(const char *text, double *value) {
    char *end = NULL;
    errno = 0; *value = strtod(text, &end);
    return errno == 0 && end != text && *end == '\0' && isfinite(*value);
}

int main(int argc, char **argv) {
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) {
        fputs("Cannot read Mach timebase\n", stderr); return 1;
    }
    if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return self_test();
    if (argc < 2 || argc > 4) {
        fprintf(stderr, "Usage: %s PID [SECONDS=180] [INTERVAL=5] | --self-test\n", argv[0]); return 1;
    }
    char *end = NULL; errno = 0;
    long pid_value = strtol(argv[1], &end, 10);
    double duration = 180, interval = 5;
    if (errno != 0 || end == argv[1] || *end || pid_value <= 0 || pid_value > INT_MAX ||
        (argc > 2 && !parse_double(argv[2], &duration)) ||
        (argc > 3 && !parse_double(argv[3], &interval)) ||
        duration < 0.25 || duration > 86400 || interval < 0.25 || interval > 3600) {
        fputs("Invalid PID/duration/interval (duration .25..86400s, interval .25..3600s)\n", stderr); return 1;
    }
    size_t intervals = (size_t)ceil(duration / interval);
    if (intervals > 10000) { fputs("At most 10000 sample intervals are allowed\n", stderr); return 1; }
    EnergySample *samples = calloc(intervals + 1, sizeof(*samples));
    if (!samples) { perror("calloc"); return 1; }
    pid_t pid = (pid_t)pid_value;
    int error = capture(pid, &samples[0]);
    if (error) {
        printf("{\"status\":\"unavailable\",\"pid\":%d,\"scope\":\"process CPU energy only\",\"error\":", pid);
        print_error(error); puts("}"); free(samples); return 2;
    }
    size_t count = 1;
    bool identity_stable = samples[0].info.ri_proc_start_abstime != 0;
    bool monotonic = true, long_gap = false;
    double largest_gap = 0;
    for (size_t i = 1; i <= intervals; ++i) {
        sleep_until(samples[0].at + fmin((double)i * interval, duration));
        error = capture(pid, &samples[count]);
        if (error) break;
        EnergySample *previous = &samples[count - 1], *current = &samples[count];
        identity_stable = identity_stable && same_process(&samples[0], current);
        monotonic = monotonic && counters_monotonic(previous, current);
        double gap = current->at - previous->at;
        if (gap > largest_gap) largest_gap = gap;
        if (gap > fmax(interval * 2.0, interval + 2.0)) long_gap = true;
        ++count;
        if (!identity_stable || !monotonic) break;
    }
    const EnergySample *first = &samples[0], *last = &samples[count - 1];
    double elapsed = last->at - first->at;
    bool supported = last->info.ri_energy_nj != 0;
    bool valid = !error && count > 1 && identity_stable && monotonic && !long_gap && elapsed > 0;
    bool measured = valid && supported;
    long double energy_delta = (long double)last->info.ri_energy_nj - first->info.ri_energy_nj;
    long double penergy_delta = (long double)last->info.ri_penergy_nj - first->info.ri_penergy_nj;
    long double cpu_delta = cpu_seconds(&last->info) - cpu_seconds(&first->info);
    double maximum_watts = 0;
    if (measured) {
        for (size_t i = 1; i < count; ++i) {
            double watts = (samples[i].info.ri_energy_nj - samples[i - 1].info.ri_energy_nj) / 1e9 / (samples[i].at - samples[i - 1].at);
            if (watts > maximum_watts) maximum_watts = watts;
        }
    }
    printf("{\n  \"status\":"); json_string(measured ? "ok" : supported ? "invalid_window" : "energy_counter_unavailable");
    printf(",\n  \"scope\":\"process CPU-attributed energy only; excludes whole-battery, display, GPU and uncharged system overhead\","
           "\n  \"pid\":%d,\n  \"process_start_mach_ticks\":%" PRIu64
           ",\n  \"requested_seconds\":%.9f,\n  \"interval_seconds\":%.9f,\n  \"duration_seconds\":%.9f,"
           "\n  \"sample_count\":%zu,\n  \"energy_counter_supported\":%s,\n  \"identity_stable\":%s,"
           "\n  \"counters_monotonic\":%s,\n  \"long_sample_gap_detected\":%s,\n  \"maximum_sample_gap_seconds\":%.9f,"
           "\n  \"mach_timebase_numer\":%u,\n  \"mach_timebase_denom\":%u,\n  \"cpu_seconds_delta\":%.12Lf,",
           pid, first->info.ri_proc_start_abstime, duration, interval, elapsed, count,
           supported ? "true" : "false", identity_stable ? "true" : "false",
           monotonic ? "true" : "false", long_gap ? "true" : "false", largest_gap,
           timebase.numer, timebase.denom, cpu_delta);
    printf("\n  \"cpu_percent_one_core\":");
    if (valid) printf("%.12Lf", cpu_delta / elapsed * 100.0L); else printf("null");
    printf(",\n  \"cpu_energy_j\":");
    if (measured) printf("%.12Lf", energy_delta / 1e9L); else printf("null");
    printf(",\n  \"average_cpu_power_w\":");
    if (measured) printf("%.12Lf", energy_delta / 1e9L / elapsed); else printf("null");
    printf(",\n  \"maximum_interval_cpu_power_w\":");
    if (measured) printf("%.12f", maximum_watts); else printf("null");
    printf(",\n  \"average_performance_core_power_w_subset\":");
    if (measured) printf("%.12Lf", penergy_delta / 1e9L / elapsed); else printf("null");
    printf(",\n  \"cpu_energy_wh\":");
    if (measured) printf("%.15Lf", energy_delta / 1e9L / 3600.0L); else printf("null");
    printf(",\n  \"package_idle_wakeups_delta\":%.0Lf,\n  \"interrupt_wakeups_delta\":%.0Lf,"
           "\n  \"disk_bytes_read_delta\":%.0Lf,\n  \"disk_bytes_written_delta\":%.0Lf,"
           "\n  \"logical_write_bytes_delta\":%.0Lf,\n  \"billed_energy_counter_delta\":%.0Lf,"
           "\n  \"serviced_energy_counter_delta\":%.0Lf,\n  \"error\":",
           (long double)last->info.ri_pkg_idle_wkups - first->info.ri_pkg_idle_wkups,
           (long double)last->info.ri_interrupt_wkups - first->info.ri_interrupt_wkups,
           (long double)last->info.ri_diskio_bytesread - first->info.ri_diskio_bytesread,
           (long double)last->info.ri_diskio_byteswritten - first->info.ri_diskio_byteswritten,
           (long double)last->info.ri_logical_writes - first->info.ri_logical_writes,
           (long double)last->info.ri_billed_energy - first->info.ri_billed_energy,
           (long double)last->info.ri_serviced_energy - first->info.ri_serviced_energy);
    if (error) print_error(error); else printf("null");
    printf(",\n  \"notes\":[\"P-core energy is a subset, never add it to total CPU energy\","
           "\"Nonzero lifetime CPU energy confirms support; zero interval delta alone does not imply unsupported or absolute zero battery use\","
           "\"Bank billed/serviced counters are reported separately and are not added to raw CPU attribution\"],\n  \"samples\":[\n");
    for (size_t i = 0; i < count; ++i) {
        printf("    "); print_sample(&samples[i], first->at);
        printf(i + 1 == count ? "\n" : ",\n");
    }
    printf("  ]\n}\n");
    free(samples);
    return measured ? 0 : 2;
}
