#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch="$root/android/patches/android-15.0.0_r36/0043-task-persister-handle-uncreated-recents-directories.patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

[ "$(grep -c '^diff --git ' "$patch")" -eq 1 ]
grep -Fq '+++ b/frameworks/base/services/core/java/com/android/server/wm/TaskPersister.java' "$patch"
[ "$(grep -c '^-[^-]' "$patch")" -eq 2 ]
grep -Fqx -- '-            removeObsoleteFiles(persistentTaskIds, getUserImagesDir(userId).listFiles());' "$patch"
grep -Fqx -- '-            removeObsoleteFiles(persistentTaskIds, getUserTasksDir(userId).listFiles());' "$patch"
grep -Fq '"1".equals(System.getenv("ROYD_CONTAINER"))' "$patch"
grep -Fq '&& !SELinux.isSELinuxEnabled()' "$patch"
grep -Fq 'Os.lstat(directory.getPath());' "$patch"
grep -Fq 'e.errno == OsConstants.ENOENT && directory.getParentFile().isDirectory()' "$patch"
grep -Fq 'sLoggedUncreatedRecentsDirectory.compareAndSet(false, true)' "$patch"
grep -Fq '+        return files;' "$patch"
! grep -Eq '^\+.*(mkdir|delete|startWrite|finishWrite|failWrite)' "$patch"

# Execute the exact added helper when a JDK is supplied, without adding a mandatory JDK
# dependency to lightweight CI. Real temporary directories exercise lazy creation too.
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  cat >"$tmp/Recents.java" <<'JAVA'
import java.io.File;
import java.nio.file.Files;
import java.util.concurrent.atomic.AtomicBoolean;

class Recents {
    static final String TAG = "TaskPersister";
    static final AtomicBoolean sLoggedUncreatedRecentsDirectory = new AtomicBoolean();
    static String marker;
    static boolean selinux;
    static int errno;
    static int statCalls;
    static int logs;
    static class System {
        static String getenv(String key) {
            check("ROYD_CONTAINER".equals(key));
            return marker;
        }
    }
    static class SELinux {
        static boolean isSELinuxEnabled() { return selinux; }
    }
    static class ErrnoException extends Exception {
        final int errno;
        ErrnoException(int value) { errno = value; }
    }
    static class OsConstants {
        static final int ENOENT = 2;
    }
    static class Os {
        static void lstat(String path) throws ErrnoException {
            check(path.endsWith("recent_images") || path.endsWith("recent_tasks"));
            statCalls++;
            if (errno != 0) throw new ErrnoException(errno);
        }
    }
    static class Slog {
        static void i(String tag, String message) {
            check(TAG.equals(tag));
            check("ROYD: no obsolete files in uncreated recents directories".equals(message));
            logs++;
        }
    }
    static void check(boolean condition) {
        if (!condition) throw new AssertionError();
    }
JAVA
  awk '
    /^\+    private static File\[\] listRecentsFiles/ { copy = 1 }
    copy && /^\+/ { print substr($0, 2) }
    copy && /^\+    }/ { exit }
  ' "$patch" >>"$tmp/Recents.java"
  cat >>"$tmp/Recents.java" <<'JAVA'
    public static void main(String[] args) throws Exception {
        File parent = new File(args[0]);
        File absent = new File(parent, "recent_images");
        File missingParent = new File(parent, "missing/recent_images");
        for (String value : new String[] {null, "", "0", "true", "1"}) {
            for (boolean enabled : new boolean[] {false, true}) {
                for (int error : new int[] {0, 2, 5, 13, 20}) {
                    for (File directory : new File[] {absent, missingParent}) {
                        marker = value;
                        selinux = enabled;
                        errno = error;
                        logs = statCalls = 0;
                        sLoggedUncreatedRecentsDirectory.set(false);
                        boolean gated = "1".equals(value) && !enabled;
                        boolean empty = gated && error == 2 && directory == absent;
                        File[] result = listRecentsFiles(directory);
                        check(empty ? result != null && result.length == 0 : result == null);
                        check(statCalls == (gated ? 1 : 0));
                        check(logs == (empty ? 1 : 0));
                        check(!directory.exists());
                    }
                }
            }
        }
        marker = "1";
        selinux = false;
        errno = 2;
        logs = statCalls = 0;
        sLoggedUncreatedRecentsDirectory.set(false);
        check(listRecentsFiles(absent).length == 0);
        check(listRecentsFiles(absent).length == 0);
        check(listRecentsFiles(new File(parent, "recent_tasks")).length == 0);
        check(logs == 1 && statCalls == 3);

        // Do not cache absence: subsequent task/icon writes must be visible to cleanup.
        check(absent.mkdir());
        statCalls = 0;
        check(listRecentsFiles(absent).length == 0);
        File icon = new File(absent, "7_icon.png");
        Files.write(icon.toPath(), new byte[] {1});
        check(listRecentsFiles(absent).length == 1 && icon.isFile());
        check(statCalls == 0 && logs == 1);
        // ENOTDIR and list errors on an existing directory must retain the stock null result.
        check(listRecentsFiles(new File(icon, "recent_images")) == null);
        File unreadable = new File(absent.getPath()) {
            @Override public File[] listFiles() { return null; }
        };
        errno = 0;
        check(listRecentsFiles(unreadable) == null);
        check(logs == 1);
        // lstat succeeds for a dangling symlink, so it must not become an empty directory.
        File link = new File(parent, "recent_tasks");
        Files.createSymbolicLink(link.toPath(), new File(parent, "missing-target").toPath());
        check(listRecentsFiles(link) == null && logs == 1);
    }
}
JAVA
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/Recents.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" Recents "$tmp"
fi
printf '%s\n' 'Android 15 TaskPersister container contract passed'
