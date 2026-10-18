package androidx.core.content; import android.content.Context;
public class ContextCompat {
    public static boolean granted=true, bluetoothGranted=false;
    public static int checkSelfPermission(Context c,String p) {
        return (p.equals("android.permission.RECORD_AUDIO") && granted)
            || (p.equals("android.permission.BLUETOOTH_CONNECT") && bluetoothGranted) ? 0 : -1;
    }
}
