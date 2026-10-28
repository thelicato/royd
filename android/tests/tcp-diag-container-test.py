"""Apply the AOSP patch and execute its actual helper and polling methods."""
from pathlib import Path
import os
import subprocess
import sys

root, temporary = map(Path, sys.argv[1:])
relative = Path('packages/modules/NetworkStack/src/com/android/networkstack/netlink')
source = temporary/relative/'TcpSocketTracker.java'
source.parent.mkdir(parents=True)
source.write_bytes((root/'android/tests/fixtures/android15/TcpSocketTracker.java').read_bytes())
patch = root/'android/patches/android-15.0.0_r36/0074-networkstack-report-unavailable-tcp-diag.patch'
subprocess.run(['patch', '--fuzz=0', '-s', '-p1', '-d', str(temporary)],
               input=patch.read_bytes(), check=True)
patched = source.read_text()


def method(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    for index in range(opening+1, len(text)):
        depth += (text[index] == '{') - (text[index] == '}')
        if depth == 0:
            return text[start:index+1]+'\n'
    raise AssertionError(signature)


signatures = ['public boolean pollSocketsInfo()', 'boolean parseMessage(',
              'private int getLengthAndVerifyMsgHeader(', 'private void cleanupSocketInfo(',
              'public boolean isDataStallSuspected()', 'private TcpStat calculateLatestPacketsStat(',
              'public int getLatestPacketFailPercentage()', 'public int getSentSinceLastRecv()',
              'public int getLatestReceivedCount()', 'private static boolean isValidInetDiagMsgSize(']
helper = temporary/relative/'RoydTcpDiag.java'
if os.environ.get('ROYD_ANDROID15_TCP_DIAG_SOURCE'):
    actual = Path(os.environ['ROYD_ANDROID15_TCP_DIAG_SOURCE'])/relative
    assert (actual/'RoydTcpDiag.java').read_bytes() == helper.read_bytes()
    text = (actual/'TcpSocketTracker.java').read_text()
    for signature in signatures:
        assert method(text, signature) == method(patched, signature), signature
    assert 'private final RoydTcpDiag mRoydTcpDiag = new RoydTcpDiag();' in text

java_home = os.environ.get('ROYD_TEST_JAVA_HOME')
if not java_home:
    print('Java execution not run: set ROYD_TEST_JAVA_HOME')
    sys.exit(0)
classes = temporary/'classes'
classes.mkdir()
stubs = {
    'android/system/ErrnoException.java': 'package android.system; public class ErrnoException extends Exception { public final int errno; public ErrnoException(int n){errno=n;} }',
    'android/system/OsConstants.java': 'package android.system; public class OsConstants { public static final int ENOENT=2,AF_INET=2,AF_INET6=10; }',
    'android/system/Os.java': '''package android.system; public class Os {
        public static int probes;
        public static void stat(String path) throws ErrnoException {
            probes++;
            if(!path.equals("/sys/fs/selinux/enforce"))throw new AssertionError();
            int n=Integer.getInteger("test.errno",0);if(n!=0)throw new ErrnoException(n);
        }}''',
    'com/android/net/module/util/netlink/StructNlMsgHdr.java': '''package com.android.net.module.util.netlink;
        import java.nio.ByteBuffer;
        public class StructNlMsgHdr {
            public static final int STRUCT_SIZE=16;public int nlmsg_len,nlmsg_seq,nlmsg_flags,nlmsg_type;
            public static StructNlMsgHdr parse(ByteBuffer b){
                if(b.remaining()<16)return null;StructNlMsgHdr h=new StructNlMsgHdr();
                h.nlmsg_len=b.getInt();h.nlmsg_type=b.getShort()&65535;h.nlmsg_flags=b.getShort()&65535;
                h.nlmsg_seq=b.getInt();b.getInt();return h;
            }}''',
}
paths = []
for name, text in stubs.items():
    path = temporary/name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    paths.append(path)
text = (root/'android/tests/tcp-diag-harness.java.in').read_text().replace(
    '// PRODUCTION_METHODS', '\n'.join(method(patched, signature) for signature in signatures))
harness = temporary/relative/'TcpDiagContract.java'
harness.write_text(text)
paths += [helper, harness]
javac, java = [str(Path(java_home)/'bin'/name) for name in ('javac', 'java')]
subprocess.run([javac, '-d', str(classes), *map(str, paths)], check=True)
for marker in (None, '', '0', 'true', '1', '01', ' 1'):
    for errno in (0, 2, 5, 13, 20):
        environment = dict(os.environ)
        environment.pop('ROYD_CONTAINER', None)
        if marker is not None:
            environment['ROYD_CONTAINER'] = marker
        subprocess.run([java, '-Dtest.errno='+str(errno), '-cp', str(classes),
                        'com.android.networkstack.netlink.TcpDiagContract'],
                       env=environment, check=True, timeout=20)
print('Android 15 TCP diagnostic container contract passed: 35 gate combinations')

original_helper = helper.read_text()
original_harness = harness.read_text()
mutations = [
    (helper, 'throw new Unavailable();', 'return;'),
    (helper, 'mUnavailable = true;', 'mUnavailable = false;'),
    (harness, 'if (mRoydTcpDiag.isUnavailable()) return -1;\n        return mLatestReceivedCount;',
     'return mLatestReceivedCount;'),
    (harness, 'SocketUtils.closeSocketQuietly(fd);', ''),
    (harness, 'if (mRoydTcpDiag.isIncompleteRecovery()) return false;', ''),
    (helper, 'mRecoveryBroken = true;', 'mRecoveryBroken = false;'),
    (helper, 'bytes.getInt(bytes.position()) != 0', 'false'),
]
environment = dict(os.environ, ROYD_CONTAINER='1')
for index, (target, old, new) in enumerate(mutations):
    helper.write_text(original_helper)
    harness.write_text(original_harness)
    text = target.read_text()
    assert text.count(old) == 1, old
    target.write_text(text.replace(old, new))
    subprocess.run([javac, '-d', str(classes), *map(str, paths)], check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    result = subprocess.run([java, '-Dtest.errno=2', '-cp', str(classes),
                             'com.android.networkstack.netlink.TcpDiagContract'],
                            env=environment, capture_output=True, timeout=20)
    assert result.returncode != 0 and b'AssertionError' in result.stderr, index
print('Seven missing-error/state/closure/recovery mutations rejected')
