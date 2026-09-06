/* cltool.c: the `unison` command that launches unison-ui-mac.
 *
 * Installed on PATH under the name `unison`, as a symlink to this file inside
 * the app bundle (the cask's `binary` stanza, or a manual link in
 * /usr/local/bin). It resolves the app's main executable and replaces itself
 * with it via execv, passing every argument through unchanged. The app then
 * decides between its graphical and headless roles from those arguments (see
 * Sources/App/CommandLineInvocationPolicy.swift), so `unison -ui graphic`
 * opens the app and `unison -server`, spawned over ssh by a remote peer,
 * serves the sync with the embedded engine.
 *
 * Because the process is replaced rather than spawned, stdin, stdout, stderr,
 * the exit status and the ssh pipe all belong to the app directly.
 *
 * Resolution order:
 *   1. Self-relative: this tool's own real path with `cltool` replaced by the
 *      app executable name. This is the path taken when the tool is reached
 *      through a symlink. Deterministic; needs no Launch Services.
 *   2. Bundle identifier through Launch Services, only when (1) finds no
 *      executable (the tool was copied out of the bundle). Exactly one
 *      registered application is required: with a Debug build registered next
 *      to the installed release, guessing would silently run the wrong one.
 *
 * Never writes to stdout. When the app runs as `unison -server`, stdout is the
 * wire protocol; every diagnostic here goes to stderr.
 *
 * CLTOOL_BUNDLE_ID and CLTOOL_APP_EXECUTABLE can be overridden at compile time
 * so scripts/test-cltool.sh can exercise the fallback against an identifier no
 * installed application carries.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef CLTOOL_BUNDLE_ID
#define CLTOOL_BUNDLE_ID "net.courbage.unison-ui-mac"
#endif
#ifndef CLTOOL_APP_EXECUTABLE
#define CLTOOL_APP_EXECUTABLE "unison-ui-mac"
#endif

static int is_executable_file(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode) && access(path, X_OK) == 0;
}

/* (1) The app executable next to this tool's real location. */
static int resolve_self_relative(char *out, size_t outsz) {
    char self[PATH_MAX];
    uint32_t size = sizeof self;
    if (_NSGetExecutablePath(self, &size) != 0) return 0;

    char real[PATH_MAX];
    if (realpath(self, real) == NULL) return 0;

    char *slash = strrchr(real, '/');
    if (slash == NULL) return 0;
    *slash = '\0';

    if (snprintf(out, outsz, "%s/%s", real, CLTOOL_APP_EXECUTABLE) >= (int)outsz) return 0;
    return is_executable_file(out);
}

static void print_url(CFURLRef url) {
    char path[PATH_MAX];
    if (CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof path)) {
        fprintf(stderr, "  %s\n", path);
    }
}

/* (2) The single registered application with our bundle identifier. */
static int resolve_by_bundle_id(char *out, size_t outsz) {
    CFArrayRef urls = LSCopyApplicationURLsForBundleIdentifier(CFSTR(CLTOOL_BUNDLE_ID), NULL);
    if (urls == NULL) {
        fprintf(stderr, "unison: no application with bundle identifier %s is registered with Launch Services\n",
                CLTOOL_BUNDLE_ID);
        return 0;
    }

    CFIndex count = CFArrayGetCount(urls);
    if (count != 1) {
        fprintf(stderr, "unison: %ld applications carry the bundle identifier %s; refusing to guess:\n",
                (long)count, CLTOOL_BUNDLE_ID);
        for (CFIndex i = 0; i < count; i++) {
            print_url((CFURLRef)CFArrayGetValueAtIndex(urls, i));
        }
        CFRelease(urls);
        return 0;
    }

    char app[PATH_MAX];
    Boolean ok = CFURLGetFileSystemRepresentation((CFURLRef)CFArrayGetValueAtIndex(urls, 0), true,
                                                  (UInt8 *)app, sizeof app);
    CFRelease(urls);
    if (!ok) {
        fprintf(stderr, "unison: cannot read the path of the registered %s application\n", CLTOOL_BUNDLE_ID);
        return 0;
    }

    if (snprintf(out, outsz, "%s/Contents/MacOS/%s", app, CLTOOL_APP_EXECUTABLE) >= (int)outsz) return 0;
    if (!is_executable_file(out)) {
        fprintf(stderr, "unison: %s has no executable at Contents/MacOS/%s\n", app, CLTOOL_APP_EXECUTABLE);
        return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    (void)argc;
    char exe[PATH_MAX];

    if (!resolve_self_relative(exe, sizeof exe) && !resolve_by_bundle_id(exe, sizeof exe)) {
        fprintf(stderr,
                "unison: cannot locate the %s application.\n"
                "Reinstall the app, or recreate the `unison` link so it points at "
                "<app bundle>/Contents/MacOS/cltool.\n",
                CLTOOL_APP_EXECUTABLE);
        return 1;
    }

    /* The app locates its bundle from its own executable path, so hand it the
     * resolved absolute path rather than whatever name the shell used. */
    argv[0] = exe;
    execv(exe, argv);

    /* Only reached if execv failed. */
    fprintf(stderr, "unison: cannot run %s: %s\n", exe, strerror(errno));
    return 1;
}
