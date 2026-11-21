#include <errno.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fputs("Usage: publish-app STAGED_APP DESTINATION\n", stderr);
        return 2;
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
