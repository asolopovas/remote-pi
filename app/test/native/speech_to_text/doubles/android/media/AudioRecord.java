package android.media;
import java.util.*;
public class AudioRecord {
 public static final int STATE_INITIALIZED=1,RECORDSTATE_RECORDING=3,READ_NON_BLOCKING=1;
 public static boolean failStart=false,failRead=false;
 public static final List<AudioRecord> created=Collections.synchronizedList(new ArrayList<>());
 public volatile boolean released=false,stopped=false; private boolean read;
 public AudioRecord(int source,int rate,int channels,int encoding,int size){created.add(this);}
 public static int getMinBufferSize(int r,int c,int e){return 3200;}
 public int getState(){return 1;} public int getRecordingState(){return 3;}
 public void startRecording(){if(failStart)throw new IllegalStateException("audio start");}
 public int read(byte[] b,int offset,int count,int mode){if(failRead)return -3;if(read)return 0;read=true;for(int i=0;i<8;i++)b[i]=(byte)i;return 8;}
 public void stop(){stopped=true;} public void release(){released=true;}
}
