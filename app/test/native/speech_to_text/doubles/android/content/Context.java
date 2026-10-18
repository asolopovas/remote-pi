package android.content; import android.content.pm.ApplicationInfo;
public class Context { public ApplicationInfo getApplicationInfo(){ApplicationInfo a=new ApplicationInfo();a.packageName="test.local";return a;} }
