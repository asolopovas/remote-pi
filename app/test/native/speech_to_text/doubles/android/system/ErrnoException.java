package android.system;
public class ErrnoException extends Exception {public final int errno;public ErrnoException(String f,int e){errno=e;}}
