/* Numeric-only macOS physical footprints. No task memory or process strings. */
#include <errno.h>
#include <limits.h>
#include <libproc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>

struct entry { int pid, error; uint64_t bytes; };

int main(int argc, char **argv) {
    if (argc < 2 || argc > 513) return 2;
    struct entry entries[512] = {0};
    for (int i = 1; i < argc; ++i) {
        char *end = NULL;
        errno = 0;
        long pid = strtol(argv[i], &end, 10);
        if (errno || !argv[i][0] || *end || pid <= 0 || pid > INT_MAX) return 2;
        for (int j = 0; j < i - 1; ++j) if (entries[j].pid == pid) return 2;
        entries[i - 1].pid = (int)pid;
    }
    for (int i = 0; i < argc - 1; ++i) {
        struct rusage_info_v4 info = {0};
        errno = 0;
        if (proc_pid_rusage(entries[i].pid, RUSAGE_INFO_V4, (rusage_info_t *)&info))
            entries[i].error = errno ? errno : EIO;
        else if (info.ri_proc_exit_abstime) entries[i].error = ESRCH;
        else entries[i].bytes = info.ri_phys_footprint;
    }
    printf("{\"unit\":\"byte\",\"bytes per unit\":1,\"processes\":[");
    int first = 1;
    for (int i = 0; i < argc - 1; ++i) if (!entries[i].error) {
        printf("%s{\"pid\":%d,\"auxiliary\":{\"phys_footprint\":%llu}}",
               first ? "" : ",", entries[i].pid, (unsigned long long)entries[i].bytes);
        first = 0;
    }
    printf("],\"errors\":[");
    first = 1;
    for (int i = 0; i < argc - 1; ++i) if (entries[i].error) {
        printf("%s{\"pid\":%d,\"errno\":%d}", first ? "" : ",", entries[i].pid, entries[i].error);
        first = 0;
    }
    puts("]}");
    return ferror(stdout) ? 1 : 0;
}
