class Bundle { }
class WindowManager {
    static class LayoutParams { static final int FLAG_KEEP_SCREEN_ON = 128; }
}
class Window {
    int flags;
    void addFlags(int value) { flags |= value; }
}
class Intent {
    boolean foreground;
    Class<?> component;
    Intent() { }
    Intent(Activity owner, Class<?> target) { component = target; }
    void putExtras(Intent other) { foreground = other.foreground; }
    boolean getBooleanExtra(String key, boolean fallback) {
        if (!key.equals("foreground")) throw new AssertionError();
        return foreground;
    }
}
class MeteredProbeService { }
class Activity {
    final Window window = new Window();
    final Intent intent = new Intent();
    int starts, finishes, resumes;
    boolean created;
    public void onCreate(Bundle state) { created = true; }
    public void onResume() { resumes++; }
    public void onWindowFocusChanged(boolean hasFocus) { }
    Window getWindow() { return window; }
    Intent getIntent() { return intent; }
    void startService(Intent service) {
        check(created && window.flags == WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        check(service.component == MeteredProbeService.class && service.foreground == intent.foreground);
        starts++;
    }
    void finishAndRemoveTask() { finishes++; }
    static void check(boolean condition) { if (!condition) throw new AssertionError(); }
}
public class LauncherTest {
    public static void main(String[] args) {
        for (boolean foreground : new boolean[] {false, true}) {
            MeteredProbeLauncher launcher = new MeteredProbeLauncher();
            launcher.intent.foreground = foreground;
            launcher.onCreate(new Bundle());
            Activity.check(launcher.starts == 0 && launcher.finishes == 0);
            launcher.onResume();
            Activity.check(launcher.starts == 0 && launcher.finishes == 0);
            launcher.onWindowFocusChanged(false);
            Activity.check(launcher.starts == 0 && launcher.finishes == 0);
            launcher.onWindowFocusChanged(true);
            Activity.check(launcher.starts == 1 && launcher.finishes == (foreground ? 0 : 1));
            launcher.onResume();
            launcher.onWindowFocusChanged(false);
            launcher.onWindowFocusChanged(true);
            Activity.check(launcher.starts == 1 && launcher.finishes == (foreground ? 0 : 1));
        }
        System.out.println("Production launcher visible-window/background-service lifecycle passed");
    }
}
