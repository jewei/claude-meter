// Development-only macOS sampler. Does not read credentials, process arguments,
// network payloads, or application memory. Redirect output outside the repository.
// Build: clang -O2 scripts/measure-runtime.c -o /tmp/measure-runtime
// Run:   /tmp/measure-runtime PID SAMPLE_COUNT > /tmp/resources.csv
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3 || atoi(argv[1]) <= 0 || atoi(argv[2]) <= 0) {
        fprintf(stderr, "Usage: measure-runtime PID SAMPLE_COUNT (one sample per 200 ms)\n");
        return 2;
    }
    int pid = atoi(argv[1]), samples = atoi(argv[2]);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    puts("elapsed,cpu_seconds,rss_bytes,footprint_bytes,idle_wakeups,interrupt_wakeups,disk_read_bytes,disk_write_bytes,children");
    for (int i = 0; i < samples; i++) {
        struct rusage_info_v2 r = {0};
        if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&r) != 0) {
            perror("proc_pid_rusage");
            return 3;
        }
        clock_gettime(CLOCK_MONOTONIC, &now);
        int pids[128];
        int bytes = proc_listchildpids(pid, pids, sizeof(pids));
        char children[4096] = "";
        for (int j = 0; j < bytes / (int)sizeof(int); j++) {
            char name[256] = {0}, item[280];
            proc_name(pids[j], name, sizeof(name));
            snprintf(item, sizeof(item), "%s%d:%s", j ? ";" : "", pids[j], name);
            strncat(children, item, sizeof(children) - strlen(children) - 1);
        }
        double elapsed = now.tv_sec - start.tv_sec + (now.tv_nsec - start.tv_nsec) / 1e9;
        // rusage CPU times use Mach absolute ticks, not nanoseconds on Apple silicon.
        double cpu = ((double)r.ri_user_time + r.ri_system_time) * timebase.numer / timebase.denom / 1e9;
        printf("%.6f,%.9f,%llu,%llu,%llu,%llu,%llu,%llu,%s\n", elapsed, cpu,
               r.ri_resident_size, r.ri_phys_footprint, r.ri_pkg_idle_wkups,
               r.ri_interrupt_wkups, r.ri_diskio_bytesread, r.ri_diskio_byteswritten, children);
        fflush(stdout);
        struct timespec pause = {0, 200000000};
        nanosleep(&pause, NULL);
    }
    return 0;
}
