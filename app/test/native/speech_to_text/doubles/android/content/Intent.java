package android.content; import java.util.*;
public class Intent { public final Map<String,Object> extras=new HashMap<>();public Intent(String action){}
 public Intent putExtra(String k,android.os.Parcelable v){extras.put(k,v);return this;}
 public Intent putExtra(String k,String v){extras.put(k,v);return this;}
 public Intent putExtra(String k,boolean v){extras.put(k,v);return this;}
 public Intent putExtra(String k,int v){extras.put(k,v);return this;}
 public Intent putExtra(String k,long v){extras.put(k,v);return this;}
}
