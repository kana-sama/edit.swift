#include <errno.h>
#include <libproc.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int unused_stage(const char *stage) {
    char stage_path[PATH_MAX];
    if (realpath(stage, stage_path) == NULL) {
        return 2;
    }

    int count = proc_listallpids(NULL, 0);
    if (count <= 0 || count >= INT_MAX / (int)sizeof(pid_t) - 64) {
        return 2;
    }

    int capacity = count + 64;
    pid_t *pids = calloc((size_t)capacity, sizeof(*pids));
    if (pids == NULL) {
        return 2;
    }

    count = proc_listallpids(pids, capacity * (int)sizeof(*pids));
    int status = 2;
    if (count > 0 && count < capacity) {
        status = 0;
        size_t length = strlen(stage_path);
        pid_t self = getpid();
        for (int index = 0; index < count; ++index) {
            char executable[PROC_PIDPATHINFO_MAXSIZE];
            if (pids[index] != self && proc_pidpath(pids[index], executable, sizeof(executable)) > 0 &&
                strncmp(stage_path, executable, length) == 0 && executable[length] == '/') {
                status = 1;
                break;
            }
        }
    }

    free(pids);
    return status;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fputs("Usage: publish-app STAGED_APP DESTINATION | publish-app unused STAGE\n", stderr);
        return 2;
    }

    if (strcmp(argv[1], "unused") == 0) {
        return unused_stage(argv[2]);
    }

    // The signed bundle is complete before it replaces the destination.
    // Swapping directories gives the new executable a fresh inode and keeps
    // the launch path available while older processes still use the old code.
    if (renamex_np(argv[1], argv[2], RENAME_EXCL) == 0) {
        return 0;
    }
    if (errno == EEXIST && renamex_np(argv[1], argv[2], RENAME_SWAP) == 0) {
        return 0;
    }
    perror(argv[2]);
    return 1;
}
