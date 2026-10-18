package android.system;
import java.io.*;
public class Os {
 public static final ByteArrayOutputStream written=new ByteArrayOutputStream();
 public static volatile int again=0;public static volatile boolean blocked=false;
 public static int fcntlInt(FileDescriptor f,int c,int v){return 0;}
 public static synchronized int write(FileDescriptor fd,byte[] b,int offset,int count)throws ErrnoException {
  if(blocked || again-->0)throw new ErrnoException("write",11);
  int n=Math.min(3,count);written.write(b,offset,n);return n;
 }
}
