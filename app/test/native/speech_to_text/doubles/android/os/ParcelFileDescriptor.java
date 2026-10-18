package android.os;
import java.io.FileDescriptor;
import java.util.*;
public class ParcelFileDescriptor implements Parcelable {
 public static final List<ParcelFileDescriptor> opened=new ArrayList<>();
 public final FileDescriptor fd=new FileDescriptor(); public volatile boolean closed;
 public ParcelFileDescriptor(){synchronized(opened){opened.add(this);}}
 public static ParcelFileDescriptor[] createPipe(){return new ParcelFileDescriptor[]{new ParcelFileDescriptor(),new ParcelFileDescriptor()};}
 public FileDescriptor getFileDescriptor(){return fd;}
 public void close(){closed=true;}
 public int describeContents(){return 0;}
 public void writeToParcel(Parcel p,int f){}
}
