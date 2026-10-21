#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
patch=$root/android/patches/android-15.0.0_r36/0063-framework-report-container-storage-pool-capacity.patch
[ "$(grep -c '^diff --git ' "$patch")" -eq 2 ]
! grep -Eq '^\+.*(Math.min|Math.max|catch.*RuntimeException|catch.*IOException|setTotalBytes|getStorageSize\(|mVold)' "$patch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
manager=frameworks/base/core/java/android/os/storage/StorageManager.java
service=frameworks/base/services/usage/java/com/android/server/usage/StorageStatsService.java
mkdir -p "$tmp/$(dirname "$manager")" "$tmp/$(dirname "$service")"
cp "$root/android/tests/fixtures/android15/StorageManager.java" "$tmp/$manager"
cp "$root/android/tests/fixtures/android15/StorageStatsService.java" "$tmp/$service"
patch --batch --fuzz=0 -p1 -d "$tmp" <"$patch" >/dev/null
manager_source=${ROYD_ANDROID15_STORAGE_MANAGER_SOURCE:-$tmp/$manager}
service_source=${ROYD_ANDROID15_STORAGE_STATS_SOURCE:-$tmp/$service}
if [ -z "${ROYD_TEST_JAVA_HOME:-}" ]; then
  printf '%s\n' 'Java execution skipped: set ROYD_TEST_JAVA_HOME for storage-capacity contracts'
  exit 0
fi
cat >"$tmp/StorageCapacityTest.java" <<'JAVA'
import java.io.IOException;
import java.util.concurrent.atomic.AtomicInteger;
class StorageCapacityTest {
    static String marker;
    static int errno, probes, statsReads, rootReads, physicalReads, volumeReads, rounds;
    static long dataBytes, rootBytes, physicalBytes, padding;
    static boolean statFailure, physicalFailure, missingVolume;
    static final AtomicInteger messages=new AtomicInteger();
    static void check(boolean ok){if(!ok)throw new AssertionError();}
    static void reset(){probes=statsReads=rootReads=physicalReads=volumeReads=rounds=0;messages.set(0);statFailure=physicalFailure=missingVolume=false;}
    static class System {
        static String getenv(String key){check(key.equals("ROYD_CONTAINER"));return marker;}
    }
    static class android {
        static class system {
            static class OsConstants {static final int ENOENT=2;}
            static class ErrnoException extends Exception {final int errno;ErrnoException(int n){errno=n;}}
            static class Os {
                static void stat(String path) throws ErrnoException {
                    check(path.equals("/sys/fs/selinux/enforce"));probes++;
                    if(errno!=0)throw new ErrnoException(errno);
                }
            }
        }
        static class os {static class StatFs extends StorageCapacityTest.StatFs {StatFs(String path){super(path);}}}
    }
    static class StatFs {
        StatFs(String path){check(path.equals("/data"));statsReads++;if(statFailure)throw new IllegalArgumentException("statvfs failure");}
        long getTotalBytes(){return dataBytes;}
    }
    static class File {
        final boolean root;
        File(boolean root){this.root=root;}
        String getAbsolutePath(){check(!root);return "/data";}
        long getTotalSpace(){if(root){rootReads++;return rootBytes;}return dataBytes;}
    }
    static class Environment {
        static File getDataDirectory(){return new File(false);}
        static File getRootDirectory(){return new File(true);}
    }
    static class FileUtils {static long roundStorageSize(long size){rounds++;return size+padding;}}
    static class Pair<A,B> {
        final A first; final B second;
        Pair(A a,B b){first=a;second=b;}
        static <A,B> Pair<A,B> create(A a,B b){return new Pair<>(a,b);}
    }
    static class VolumeInfo {final Disk disk=new Disk();}
    static class Disk {long size=123456789L;}
    static class ParcelableException extends RuntimeException {ParcelableException(Exception cause){super(cause);}}
    static class DataUnit {static final DataUnit GIGABYTES=new DataUnit();long toBytes(long n){return n*1000000000L;}}
    static class Slog {
        static void i(String tag,String text){check(tag.equals("StorageStatsService"));check(text.equals("ROYD: reporting /data filesystem capacity for container storage"));messages.incrementAndGet();}
    }
    static class StorageManager {
        static final String UUID_PRIVATE_INTERNAL=null;
        long getInternalStorageBlockDeviceSize(){physicalReads++;if(physicalFailure)throw new SecurityException("physical lookup denied");return physicalBytes;}
        VolumeInfo findVolumeByUuid(String uuid){check(uuid.equals("external"));volumeReads++;return missingVolume?null:new VolumeInfo();}
JAVA
awk '
  /^    (public static Pair<String, Long> getPrimaryStoragePathAndSize|public long getPrimaryStorageSize|private static boolean isRoydContainerStorage)\(/ {copy=1}
  copy {print}
  copy && /^    }/ {copy=0}
' "$manager_source" >>"$tmp/StorageCapacityTest.java"
cat >>"$tmp/StorageCapacityTest.java" <<'JAVA'
    }
    static class StorageStatsService {
        static final String TAG="StorageStatsService";
        final StorageManager mStorage=new StorageManager();
JAVA
awk '
  /private final java.util.concurrent.atomic.AtomicBoolean mRoydStorageReported/ {print;getline;print}
  /^    (public long getTotalBytes|private static boolean isRoydContainerStorage)\(/ {copy=1}
  copy {print}
  copy && /^    }/ {copy=0}
' "$service_source" >>"$tmp/StorageCapacityTest.java"
cat >>"$tmp/StorageCapacityTest.java" <<'JAVA'
    }
    public static void main(String[] args) {
        int cases=0;
        long[] sizes={0,1,511999999999L,512000000000L,512000000001L,518933680128L,1000000000000L,8000000000000L};
        for(String env:new String[]{null,"","0","true","1"})
        for(int error:new int[]{0,2,5,13,20})
        for(long size:sizes)
        for(long root:new long[]{0,16000000000L,518933680128L,4000000000000L})
        for(long pad:new long[]{0,3000000000L,4000000000L}) {
            reset();marker=env;errno=error;dataBytes=size;rootBytes=root;padding=pad;
            boolean gate="1".equals(env) && error==2;
            StorageManager manager=new StorageManager();
            long expected=gate?dataBytes:dataBytes+rootBytes+padding;
            check(manager.getPrimaryStorageSize()==expected);
            Pair<String,Long> pair=StorageManager.getPrimaryStoragePathAndSize();
            check(pair.first==null && pair.second==expected);
            check(rootReads==(gate?0:2) && statsReads==(gate?2:0) && rounds==(gate?0:2));
            check(probes==("1".equals(env)?2:0));
            for(boolean failure:new boolean[]{false,true}) {
                reset();physicalFailure=failure;physicalBytes=999000000000L;
                StorageStatsService service=new StorageStatsService();
                boolean physical=!gate && dataBytes+rootBytes+padding>512000000000L;
                long result=gate?dataBytes:physical?(padding<=3000000000L?physicalBytes+padding:physicalBytes):expected;
                boolean threw=false;
                try{check(service.getTotalBytes(null,"ordinary.test")==result);}
                catch(SecurityException denied){threw=true;}
                check(threw==(physical && failure));
                check(physicalReads==(physical?1:0) && rootReads==(gate?0:1));
                check(statsReads==(gate?1:0) && messages.get()==(gate?1:0));
                if(gate){dataBytes++;check(service.getTotalBytes(null,"ordinary.test")==dataBytes);dataBytes--;check(messages.get()==1);}
                cases++;
            }
            for(boolean missing:new boolean[]{false,true}) {
                reset();missingVolume=missing;
                StorageStatsService service=new StorageStatsService();boolean threw=false;
                try{check(service.getTotalBytes("external","ordinary.test")==123456789L+padding);}
                catch(ParcelableException absent){check(absent.getCause() instanceof IOException);threw=true;}
                check(threw==missing && volumeReads==1 && physicalReads==0 && rootReads==0 && statsReads==0 && probes==0 && messages.get()==0);cases++;
            }
        }
        reset();marker="1";errno=2;dataBytes=518933680128L;statFailure=true;
        try{new StorageManager().getPrimaryStorageSize();throw new AssertionError();}catch(IllegalArgumentException expected){}
        try{StorageManager.getPrimaryStoragePathAndSize();throw new AssertionError();}catch(IllegalArgumentException expected){}
        try{new StorageStatsService().getTotalBytes(null,"ordinary.test");throw new AssertionError();}catch(IllegalArgumentException expected){}
        check(messages.get()==0 && physicalReads==0 && rootReads==0);
        reset();StorageStatsService service=new StorageStatsService();
        java.util.stream.IntStream.range(0,64).parallel().forEach(i->check(service.getTotalBytes(null,"ordinary.test")==518933680128L));
        check(messages.get()==1 && physicalReads==0);
        java.lang.System.out.println("Patched primary/pair/stats capacity contracts passed: "+cases+" combinations, fresh reads, exact gates, stock failures and concurrent bounded marker");
    }
}
JAVA
"$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/StorageCapacityTest.java"
"$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" StorageCapacityTest
