package androidx.core.app;
import android.app.Activity;
public class ActivityCompat {
    public static int prompts;
    public static String[] requested;
    public static void requestPermissions(Activity a,String[] p,int code) {
        prompts++;
        requested=p.clone();
    }
}
