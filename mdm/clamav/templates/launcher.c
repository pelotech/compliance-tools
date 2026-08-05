// Main executable of the ClamAV GUI bundle. Prepends the ClamAV CLI to PATH and
// hands off to the real application binary, which is renamed alongside it.
//
// Why this exists, and why it is compiled rather than a shell script:
//
//   The GUI resolves `clamscan` from PATH. launchd hands GUI apps
//   PATH=/usr/bin:/bin:/usr/sbin:/sbin, and Cisco installs to
//   /usr/local/clamav/bin, which is not on it. LSEnvironment in Info.plist does
//   not help -- it only supplies variables the launch does not already provide,
//   and launchd always provides a PATH. Symlinks in /usr/local/bin do not help
//   either, because that directory is not on launchd's PATH. Setting PATH
//   inside the process is the only approach that cannot be overridden.
//
//   A shell script cannot do this job: launchd refuses to spawn an app whose
//   main executable is not Mach-O, failing with "Launchd job spawn failed".
//
// The real binary is located relative to this executable rather than by an
// absolute path, so the bundle stays relocatable.
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CLI_DIR "__CLAMAV_DIR__/bin"
#define REAL_BINARY "__REAL_BINARY__"

int main(int argc, char *argv[]) {
    (void)argc;

    char self[PATH_MAX];
    uint32_t size = (uint32_t)sizeof self;
    if (_NSGetExecutablePath(self, &size) != 0) {
        fprintf(stderr, "clamav-gui: cannot determine own path\n");
        return 127;
    }

    char *slash = strrchr(self, '/');
    if (slash == NULL) {
        fprintf(stderr, "clamav-gui: own path has no directory component\n");
        return 127;
    }
    *slash = '\0';

    char target[PATH_MAX];
    if (snprintf(target, sizeof target, "%s/%s", self, REAL_BINARY) >= (int)sizeof target) {
        fprintf(stderr, "clamav-gui: path to %s too long\n", REAL_BINARY);
        return 127;
    }

    // Prepend rather than replace, so a PATH inherited from a terminal launch
    // still works and the CLI simply takes precedence.
    const char *inherited = getenv("PATH");
    char path[4096];
    if (inherited != NULL && *inherited != '\0') {
        if (snprintf(path, sizeof path, CLI_DIR ":%s", inherited) >= (int)sizeof path) {
            // Inherited PATH is pathologically long; ours alone still beats
            // failing to launch.
            snprintf(path, sizeof path, CLI_DIR ":/usr/bin:/bin:/usr/sbin:/sbin");
        }
    } else {
        snprintf(path, sizeof path, CLI_DIR ":/usr/bin:/bin:/usr/sbin:/sbin");
    }
    if (setenv("PATH", path, 1) != 0) {
        fprintf(stderr, "clamav-gui: setenv PATH failed\n");
        return 127;
    }

    execv(target, argv);

    // execv only returns on failure.
    perror("clamav-gui: exec of real binary failed");
    return 127;
}
