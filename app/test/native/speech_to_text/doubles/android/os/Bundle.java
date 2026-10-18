package android.os; import java.util.*;
public class Bundle {
 private final Map<String,Object> values=new HashMap<>();
 public void putStringArrayList(String key,ArrayList<String> value){values.put(key,value);}
 @SuppressWarnings("unchecked") public ArrayList<String> getStringArrayList(String key){return (ArrayList<String>)values.get(key);}
 public float[] getFloatArray(String key){return (float[])values.get(key);}
 public boolean getBoolean(String key,boolean fallback){return values.containsKey(key)?(Boolean)values.get(key):fallback;}
}
