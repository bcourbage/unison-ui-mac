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
 * Resolution:
 *   1. Inside a bundle. When this tool's real path ends in
 *      /Contents/MacOS/cltool, that bundle is the only candidate: its
 *      Info.plist must carry our bundle identifier and name an executable that
 *      exists. Anything else (foreign identifier, no Info.plist, missing
 *      executable) is a damaged or foreign bundle and the tool stops. It never
 *      falls through to Launch Services from here, because "the executable next
 *      to me is missing" is bundle damage, not a reason to run some other copy.
 *   2. Outside a bundle (the tool was copied out). Launch Services is asked for
 *      applications with our identifier; exactly one is required and it is
 *      verified the same way. With a Debug build registered next to the
 *      installed release, guessing would silently run the wrong one.
 *
 * Never writes to stdout. When the app runs as `unison -server`, stdout is the
 * wire protocol; every diagnostic here goes to stderr.
 *
 * CLTOOL_BUNDLE_ID can be overridden at compile time so scripts/test-cltool.sh
 * can exercise every path against an identifier no installed application
 * carries.
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

static const char *const kBundleSuffix = "/Contents/MacOS/cltool";

static int is_executable_file(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode) && access(path, X_OK) == 0;
}

/* Verify the bundle at `bundle_path` and copy its main executable's path into
 * `out`. Returns 1 on success; on failure prints why to stderr and returns 0. */
static int executable_of_verified_bundle(const char *bundle_path, char *out, size_t outsz) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bundle_path,
                                                           (CFIndex)strlen(bundle_path), true);
    if (url == NULL) return 0;
    CFBundleRef bundle = CFBundleCreate(NULL, url);
    CFRelease(url);
    if (bundle == NULL) {
        fprintf(stderr, "unison: %s is not a readable application bundle\n", bundle_path);
        return 0;
    }

    int ok = 0;
    CFStringRef ident = CFBundleGetIdentifier(bundle);
    if (ident == NULL || CFStringCompare(ident, CFSTR(CLTOOL_BUNDLE_ID), 0) != kCFCompareEqualTo) {
        char have[256] = "(none)";
        if (ident != NULL) CFStringGetCString(ident, have, sizeof have, kCFStringEncodingUTF8);
        fprintf(stderr, "unison: %s has bundle identifier %s, expected %s\n", bundle_path, have, CLTOOL_BUNDLE_ID);
        goto done;
    }

    /* Build the executable path from CFBundleExecutable ourselves rather than
     * through CFBundleCopyExecutableURL, which returns NULL for a missing file
     * and would make "damaged" indistinguishable from "not declared". */
    CFTypeRef exe_name = CFBundleGetValueForInfoDictionaryKey(bundle, kCFBundleExecutableKey);
    char name[256];
    if (exe_name == NULL || CFGetTypeID(exe_name) != CFStringGetTypeID()
        || !CFStringGetCString((CFStringRef)exe_name, name, sizeof name, kCFStringEncodingUTF8)
        || name[0] == '\0' || strchr(name, '/') != NULL) {
        fprintf(stderr, "unison: %s names no executable in its Info.plist\n", bundle_path);
        goto done;
    }
    if (snprintf(out, outsz, "%s/Contents/MacOS/%s", bundle_path, name) >= (int)outsz) goto done;

    if (!is_executable_file(out)) {
        fprintf(stderr, "unison: %s is missing its executable (%s); the bundle is damaged\n", bundle_path, out);
        goto done;
    }
    ok = 1;

done:
    CFRelease(bundle);
    return ok;
}

/* Our own real path. 0 if it cannot be determined. */
static int self_real_path(char *out, size_t outsz) {
    char self[PATH_MAX];
    uint32_t size = sizeof self;
    if (_NSGetExecutablePath(self, &size) != 0) return 0;
    char real[PATH_MAX];
    if (realpath(self, real) == NULL) return 0;
    if (strlen(real) + 1 > outsz) return 0;
    strcpy(out, real);
    return 1;
}

/* (1) The bundle this tool lives in, if its path has the bundle layout.
 * Returns 1 and fills `bundle_out` when inside a bundle, else 0. */
static int enclosing_bundle(const char *real, char *bundle_out, size_t outsz) {
    size_t n = strlen(real), k = strlen(kBundleSuffix);
    if (n <= k || strcmp(real + n - k, kBundleSuffix) != 0) return 0;
    if (n - k + 1 > outsz) return 0;
    memcpy(bundle_out, real, n - k);
    bundle_out[n - k] = '\0';
    return 1;
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
        for (CFIndex i = 0; i < count; i++) print_url((CFURLRef)CFArrayGetValueAtIndex(urls, i));
        CFRelease(urls);
        return 0;
    }

    char app[PATH_MAX];
    Boolean got = CFURLGetFileSystemRepresentation((CFURLRef)CFArrayGetValueAtIndex(urls, 0), true,
                                                   (UInt8 *)app, sizeof app);
    CFRelease(urls);
    if (!got) {
        fprintf(stderr, "unison: cannot read the path of the registered %s application\n", CLTOOL_BUNDLE_ID);
        return 0;
    }
    return executable_of_verified_bundle(app, out, outsz);
}

int main(int argc, char **argv) {
    (void)argc;
    char real[PATH_MAX], bundle[PATH_MAX], exe[PATH_MAX];
    int resolved = 0;

    if (!self_real_path(real, sizeof real)) {
        /* Location unknown is not "known to be copied out": with the bundle
         * being replaced or removed underneath us, asking Launch Services
         * could run some other registered copy. Stop instead. */
        fprintf(stderr, "unison: cannot determine the launcher's own location: %s\n", strerror(errno));
        resolved = 0;
    } else if (enclosing_bundle(real, bundle, sizeof bundle)) {
        /* Inside a bundle: that bundle or nothing. */
        resolved = executable_of_verified_bundle(bundle, exe, sizeof exe);
    } else {
        resolved = resolve_by_bundle_id(exe, sizeof exe);
    }

    if (!resolved) {
        fprintf(stderr,
                "unison: cannot locate the unison-ui-mac application.\n"
                "Reinstall the app, or recreate the `unison` link so it points at "
                "<app bundle>/Contents/MacOS/cltool.\n");
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
